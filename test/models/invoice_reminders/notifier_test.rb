require "test_helper"
require "net/smtp"
require "openssl"

class InvoiceReminders::NotifierTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  FakeDelivery = Data.define(:callback) do
    def deliver_now
      callback.call
    end
  end
  RenderedDelivery = Data.define(:render_callback, :delivery_callback) do
    def message
      self
    end

    def encoded
      render_callback.call
    end

    def deliver_now
      delivery_callback.call
    end
  end

  setup do
    @invoice = invoices(:xero_invoice)
    message = @invoice.conversation_messages.create!(
      account: @invoice.account,
      conversation: Conversation.for_invoice!(invoice: @invoice),
      direction: :outbound,
      kind: :scheduled_reminder,
      status: :sent,
      sent_at: Time.current
    )
    @reminder = @invoice.invoice_reminders.create!(
      account: @invoice.account,
      conversation_message: message,
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      tone: :friendly
    )
  end

  test "emails only active subscribed users in the invoice account" do
    subscribed_user = create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "subscribed@example.com"
    )
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "inactive@example.com",
      active: false
    )
    create_subscriber(
      account: Account.create!(name: "Other Notification Account"),
      event: :invoice_reminder,
      email: "other-account@example.com"
    )
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "disabled@example.com",
      enabled: false
    )

    assert_emails 1 do
      InvoiceReminders::Notifier.deliver(invoice: @invoice, reminder: @reminder, terminal: false)
    end

    assert_equal [ subscribed_user.identity.email_address ], ActionMailer::Base.deliveries.last.to
  end

  test "terminal delivery sends the independently subscribed manual follow-up event" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder_stopped,
      email: "follow-up@example.com"
    )

    assert_emails 1 do
      InvoiceReminders::Notifier.deliver(invoice: @invoice, reminder: @reminder, terminal: true)
    end

    assert_equal "Final Reminder Sent for Invoice INV-001 - Manual Follow-up Required",
      ActionMailer::Base.deliveries.last.subject
  end

  test "one event failure does not prevent the terminal follow-up event" do
    user = create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "both-events@example.com"
    )
    user.notification_subscriptions.create!(event: :invoice_reminder_stopped, email: true)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).raises(StandardError, "delivery failed")
    Rails.logger.stubs(:error)

    assert_emails 1 do
      InvoiceReminders::Notifier.deliver(invoice: @invoice, reminder: @reminder, terminal: true)
    end

    assert_equal "Final Reminder Sent for Invoice INV-001 - Manual Follow-up Required",
      ActionMailer::Base.deliveries.last.subject
  end

  test "a known delivery failure stays retryable and finalizes only after retry" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "retry-notification@example.com"
    )
    attempts = 0
    delivery = FakeDelivery.new(lambda do
      attempts += 1
      raise Net::SMTPServerBusy, "451 temporary rejection" if attempts == 1
    end)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
    Rails.logger.stubs(:error)

    assert_no_difference -> {
      ConversationEvent.kind_invoice_reminder_notifications_finalized.count
    } do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end
    outcome = InvoiceReminderNotificationDelivery.sole
    assert_predicate outcome, :status_pending?
    assert_nil outcome.delivery_started_at
    assert_equal 1, outcome.attempts

    assert_difference -> {
      ConversationEvent.kind_invoice_reminder_notifications_finalized.count
    }, 1 do
      perform_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob
    end
    assert_equal 2, attempts
    assert_predicate outcome.reload, :status_delivered?
  end

  test "a known delivery failure assigns the retry to the durable delivery job" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "owned-retry@example.com"
    )
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(FakeDelivery.new(
        -> { raise Net::SMTPServerBusy, "451 retry safely" }
      ))
    Rails.logger.stubs(:error)

    assert_enqueued_with(job: InvoiceReminders::NotificationDeliveryJob) do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end

    assert_predicate InvoiceReminderNotificationDelivery.sole, :status_pending?
    assert_empty ConversationEvent.kind_invoice_reminder_notifications_finalized
  end

  test "retry sends only the known-failed recipient and not an earlier success" do
    2.times do |index|
      create_subscriber(
        account: @invoice.account,
        event: :invoice_reminder,
        email: "partial-notification-#{index}@example.com"
      )
    end
    calls = [ 0, 0 ]
    first = FakeDelivery.new(-> { calls[0] += 1 })
    second = FakeDelivery.new(lambda do
      calls[1] += 1
      raise Net::SMTPServerBusy, "451 second recipient failed" if
        calls[1] == 1
    end)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(first, second, second)
    Rails.logger.stubs(:error)

    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    )
    assert_equal [ 1, 1 ], calls
    assert_equal 1,
      InvoiceReminderNotificationDelivery.status_delivered.count
    assert_equal 1,
      InvoiceReminderNotificationDelivery.status_pending.count
    assert_empty ConversationEvent.kind_invoice_reminder_notifications_finalized

    perform_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob
    assert_equal [ 1, 2 ], calls
    assert_equal 2,
      InvoiceReminderNotificationDelivery.status_delivered.count
    assert_predicate ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole, :persisted?
  end

  test "terminal delivery retries only its failed event after normal success" do
    user = create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "terminal-partial@example.com"
    )
    user.notification_subscriptions.create!(
      event: :invoice_reminder_stopped,
      email: true
    )
    @reminder.update!(terminal_at_delivery: true)
    calls = [ 0, 0 ]
    normal = FakeDelivery.new(-> { calls[0] += 1 })
    stopped = FakeDelivery.new(lambda do
      calls[1] += 1
      raise Net::SMTPServerBusy, "451 manual follow-up notification failed" if
        calls[1] == 1
    end)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(normal)
    InvoiceReminderNotificationMailer.stubs(:manual_follow_up)
      .returns(stopped)
    Rails.logger.stubs(:error)

    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder
    )
    assert_equal [ 1, 1 ], calls
    assert_empty ConversationEvent.kind_invoice_reminder_notifications_finalized

    perform_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob
    assert_equal [ 1, 2 ], calls
    assert_equal %w[delivered delivered],
      @reminder.notification_deliveries.order(:event_name).pluck(:status)
    assert_predicate ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole, :persisted?
  end

  test "an ambiguous handoff is terminal but recorded as uncertain" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "uncertain-notification@example.com"
    )
    delivery = FakeDelivery.new(-> { raise Timeout::Error, "handoff timed out" })
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
    Rails.logger.stubs(:error)

    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    )

    outcome = InvoiceReminderNotificationDelivery.sole
    assert_predicate outcome, :status_uncertain?
    assert outcome.delivery_started_at
    assert_predicate ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole, :persisted?

    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    )
    assert_equal 1, outcome.reload.attempts
  end

  test "a TLS failure after transport starts is uncertain and never retried" do
    assert_ambiguous_transport_failure(
      OpenSSL::SSL::SSLError.new("TLS ended after DATA"),
      email: "ambiguous-tls@example.com"
    )
  end

  test "a socket timeout after transport starts is uncertain and never retried" do
    assert_ambiguous_transport_failure(
      Errno::ETIMEDOUT.new,
      email: "ambiguous-timeout@example.com"
    )
  end

  test "a connection reset after transport starts is uncertain and never retried" do
    assert_ambiguous_transport_failure(
      Errno::ECONNRESET.new,
      email: "ambiguous-reset@example.com"
    )
  end

  test "a definite SMTP rejection remains retryable" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "smtp-rejection@example.com"
    )
    error = Net::SMTPFatalError.new("550 rejected")
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(FakeDelivery.new(-> { raise error }))
    Rails.logger.stubs(:error)

    assert_enqueued_with(job: InvoiceReminders::NotificationDeliveryJob) do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end

    outcome = InvoiceReminderNotificationDelivery.sole
    assert_predicate outcome, :status_pending?
    assert_nil outcome.delivery_started_at
  end

  test "an envelope rejection before DATA acceptance remains retryable" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "envelope-rejection@example.com"
    )
    calls = 0
    delivery = FakeDelivery.new(lambda do
      calls += 1
      InvoiceReminders::SmtpDeliveryPhase.mark_envelope!
      raise Net::SMTPFatalError, "550 recipient rejected"
    end)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
    Rails.logger.stubs(:error)

    assert_enqueued_with(job: InvoiceReminders::NotificationDeliveryJob) do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end

    assert_equal 1, calls
    assert_predicate InvoiceReminderNotificationDelivery.sole,
      :status_pending?
  end

  test "pre-DATA connection loss is definitely unsent and retryable" do
    [
      [ Errno::ECONNRESET.new, "pre-data-reset" ],
      [ Net::ReadTimeout.new("read timed out"), "pre-data-timeout" ],
      [ Errno::EPIPE.new, "pre-data-pipe" ]
    ].each do |error, label|
      reminder = replacement_reminder
      create_subscriber(
        account: @invoice.account,
        event: :invoice_reminder,
        email: "#{label}@example.com"
      )
      delivery = FakeDelivery.new(lambda do
        InvoiceReminders::SmtpDeliveryPhase.mark_envelope_started!
        raise error
      end)
      InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
      Rails.logger.stubs(:error)

      assert_enqueued_with(job: InvoiceReminders::NotificationDeliveryJob) do
        InvoiceReminders::Notifier.deliver_once(
          invoice: @invoice,
          reminder:,
          terminal: false
        )
      end

      assert_predicate reminder.notification_deliveries
        .where(recipient_email: "#{label}@example.com").sole,
        :status_pending?
    end
  end

  test "connection loss after DATA starts is uncertain and never retried" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "data-handoff-loss@example.com"
    )
    delivery = FakeDelivery.new(lambda do
      InvoiceReminders::SmtpDeliveryPhase.mark_data_started!
      raise Errno::ECONNRESET
    end)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
    Rails.logger.stubs(:error)

    assert_no_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end

    assert_predicate InvoiceReminderNotificationDelivery.sole,
      :status_uncertain?
  end

  test "a definite DATA rejection is unsent and retryable" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "data-rejected@example.com"
    )
    delivery = FakeDelivery.new(lambda do
      InvoiceReminders::SmtpDeliveryPhase.mark_data_started!
      raise Net::SMTPFatalError, "554 DATA not accepted"
    end)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
    Rails.logger.stubs(:error)

    assert_enqueued_with(job: InvoiceReminders::NotificationDeliveryJob) do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end

    assert_predicate InvoiceReminderNotificationDelivery.sole,
      :status_pending?
  end

  test "a QUIT rejection after DATA acceptance never retries or duplicates" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "accepted-before-quit@example.com"
    )
    calls = 0
    delivery = FakeDelivery.new(lambda do
      calls += 1
      InvoiceReminders::SmtpDeliveryPhase.mark_envelope!
      InvoiceReminders::SmtpDeliveryPhase.mark_accepted!
      raise Net::SMTPFatalError, "550 QUIT rejected"
    end)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
    Rails.logger.stubs(:error)

    assert_no_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
      2.times do
        InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
      end
    end

    outcome = InvoiceReminderNotificationDelivery.sole
    assert_equal 1, calls
    assert_predicate outcome, :status_delivered?
    event = ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole
    assert_equal 1, event.metadata["delivered_count"]
    assert_equal 1, ConversationEvent
      .kind_invoice_reminder_notifications_finalized.count
  end

  test "SMTP authentication failure before the envelope remains retryable" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "smtp-authentication@example.com"
    )
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(FakeDelivery.new(
        -> { raise Net::SMTPAuthenticationError, "535 rejected" }
      ))
    Rails.logger.stubs(:error)

    assert_enqueued_with(job: InvoiceReminders::NotificationDeliveryJob) do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end

    assert_predicate InvoiceReminderNotificationDelivery.sole,
      :status_pending?
  end

  test "definite SMTP 4xx and 5xx responses remain retryable" do
    [
      Net::SMTPServerBusy.new("451 try later"),
      Net::SMTPFatalError.new("550 rejected")
    ].each_with_index do |error, index|
      reminder = index.zero? ? @reminder : replacement_reminder
      create_subscriber(
        account: @invoice.account,
        event: :invoice_reminder,
        email: "smtp-response-#{index}@example.com"
      )
      InvoiceReminderNotificationMailer.stubs(:reminder_sent)
        .returns(FakeDelivery.new(-> { raise error }))
      Rails.logger.stubs(:error)

      assert_enqueued_with(job: InvoiceReminders::NotificationDeliveryJob) do
        InvoiceReminders::Notifier.deliver_once(
          invoice: @invoice,
          reminder:,
          terminal: false
        )
      end

      assert_predicate reminder.notification_deliveries
        .where(recipient_email: "smtp-response-#{index}@example.com").sole,
        :status_pending?
    end
  end

  test "definite connection setup failures remain retryable" do
    errors = [
      SocketError.new("DNS unavailable"),
      Net::OpenTimeout.new("connect timed out"),
      Errno::ECONNREFUSED.new,
      Errno::EHOSTUNREACH.new,
      Errno::ENETUNREACH.new
    ]

    errors.each_with_index do |error, index|
      reminder = index.zero? ? @reminder : replacement_reminder
      create_subscriber(
        account: @invoice.account,
        event: :invoice_reminder,
        email: "connection-setup-#{index}@example.com"
      )
      InvoiceReminderNotificationMailer.stubs(:reminder_sent)
        .returns(FakeDelivery.new(-> { raise error }))
      Rails.logger.stubs(:error)

      assert_enqueued_with(job: InvoiceReminders::NotificationDeliveryJob) do
        InvoiceReminders::Notifier.deliver_once(
          invoice: @invoice,
          reminder:,
          terminal: false
        )
      end

      assert_predicate reminder.notification_deliveries
        .where(recipient_email: "connection-setup-#{index}@example.com").sole,
        :status_pending?
    end
  end

  test "an unknown SMTP response after transport starts is uncertain" do
    assert_ambiguous_transport_failure(
      Net::SMTPUnknownError.new("response after DATA was not understood"),
      email: "unknown-smtp@example.com"
    )
  end

  test "an arbitrary post-claim error defaults to uncertain" do
    assert_ambiguous_transport_failure(
      StandardError.new("unknown handoff phase"),
      email: "unknown-transport@example.com"
    )
  end

  test "a read timeout and broken pipe after transport starts are uncertain" do
    [
      [ Net::ReadTimeout.new("read timed out"), "read-timeout" ],
      [ Errno::EPIPE.new, "broken-pipe" ]
    ].each do |error, label|
      reminder = replacement_reminder
      create_subscriber(
        account: @invoice.account,
        event: :invoice_reminder,
        email: "#{label}@example.com"
      )
      InvoiceReminderNotificationMailer.stubs(:reminder_sent)
        .returns(FakeDelivery.new(-> { raise error }))
      Rails.logger.stubs(:error)

      assert_no_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob do
        InvoiceReminders::Notifier.deliver_once(
          invoice: @invoice,
          reminder:,
          terminal: false
        )
      end

      assert_predicate reminder.notification_deliveries
        .where(recipient_email: "#{label}@example.com").sole,
        :status_uncertain?
    end
  end

  test "a rendering failure happens before the transport claim and remains retryable" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "render-retry@example.com"
    )
    delivery = RenderedDelivery.new(
      -> { raise ActionView::Template::Error, "render failed" },
      -> { flunk "transport must not start" }
    )
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
    Rails.logger.stubs(:error)

    assert_enqueued_with(job: InvoiceReminders::NotificationDeliveryJob) do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end

    outcome = InvoiceReminderNotificationDelivery.sole
    assert_predicate outcome, :status_pending?
    assert_nil outcome.delivery_started_at
    assert_equal 0, outcome.attempts
  end

  test "one render failure still permits five independent transport attempts" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "independent-build-budget@example.com"
    )
    render_failure = RenderedDelivery.new(
      -> { raise ActionView::Template::Error, "render failed" },
      -> { flunk "failed rendering must not reach transport" }
    )
    transport_failures = 5.times.map do
      FakeDelivery.new(
        -> { raise Net::SMTPServerBusy, "451 rejected before DATA" }
      )
    end
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(render_failure, *transport_failures)
    Rails.logger.stubs(:error)

    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    )
    clear_enqueued_jobs
    outcome = InvoiceReminderNotificationDelivery.sole
    retry_owner = outcome.retry_job_id
    results = 5.times.map do |index|
      InvoiceReminders::Notifier.deliver_outcome(
        outcome,
        schedule_retry: false,
        retry_job_id: index.zero? ? retry_owner : nil
      )
    end

    assert_equal [ :retry, :retry, :retry, :retry, :failed ], results
    assert_predicate outcome.reload, :status_failed?
    assert_equal 1, outcome.build_attempts
    assert_equal 5, outcome.attempts
    assert_equal "transport_attempts_exhausted", outcome.terminal_reason
    assert_equal 1, ConversationEvent
      .kind_invoice_reminder_notifications_finalized.count
  end

  test "a deactivated recipient is canceled without delivery and included in the audit" do
    user = create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "deactivated-before-delivery@example.com"
    )
    InvoiceReminders::Notifier.send(
      :new,
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    ).send(:initialize_outcomes!)
    user.deactivate

    assert_no_emails do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end

    outcome = InvoiceReminderNotificationDelivery.sole
    assert_predicate outcome, :status_canceled?
    event = ConversationEvent.kind_invoice_reminder_notifications_finalized.sole
    assert_equal 1, event.metadata["canceled_count"]
    assert_equal 0, event.metadata["failed_count"]
  end

  %i[invoice_reminder invoice_reminder_stopped].each do |event_name|
    %i[disabled deleted].each do |preference_change|
      test "#{preference_change} #{event_name} preference cancels a pending retry" do
        user = create_subscriber(
          account: @invoice.account,
          event: event_name,
          email: "#{preference_change}-#{event_name}@example.com"
        )
        @reminder.update!(terminal_at_delivery: true) if
          event_name == :invoice_reminder_stopped
        notifier = InvoiceReminders::Notifier.send(
          :new,
          invoice: @invoice,
          reminder: @reminder,
          terminal: @reminder.terminal_at_delivery?
        )
        notifier.send(:initialize_outcomes!)
        outcome = @reminder.notification_deliveries.find_by!(
          recipient_user: user,
          event_name:
        )
        outcome.update!(
          attempts: 1,
          next_retry_at: Time.current,
          last_error_class: "Net::SMTPServerBusy",
          last_error_message: "451 retry"
        )
        subscription = user.notification_subscriptions.find_by!(
          event: event_name
        )
        preference_change == :disabled ?
          subscription.update!(email: false) :
          subscription.destroy!

        assert_no_emails do
          InvoiceReminders::Notifier.deliver_outcome(
            outcome,
            schedule_retry: false
          )
        end

        assert_predicate outcome.reload, :status_canceled?
        event = ConversationEvent
          .kind_invoice_reminder_notifications_finalized.sole
        assert_equal 1, event.metadata["canceled_count"]
      end
    end
  end

  test "identity drift cancels the snapshot instead of sending to the new address" do
    user = create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "immutable-snapshot@example.com"
    )
    InvoiceReminders::Notifier.send(
      :new,
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    ).send(:initialize_outcomes!)
    user.update!(
      identity: Identity.create!(email_address: "replacement-address@example.com")
    )

    assert_no_emails do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end

    assert_predicate InvoiceReminderNotificationDelivery.sole,
      :status_canceled?
  end

  test "deleting one recipient preserves its outcome and nullifies the live reference" do
    user = create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "deleted-recipient@example.com"
    )
    InvoiceReminders::Notifier.send(
      :new,
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    ).send(:initialize_outcomes!)
    outcome = InvoiceReminderNotificationDelivery.sole

    user.destroy!

    assert_predicate outcome.reload, :persisted?
    assert_nil outcome.recipient_user_id
    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    )
    assert_predicate outcome.reload, :status_canceled?
  end

  test "destroying the invoice still removes notification outcomes" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "parent-cleanup@example.com"
    )
    InvoiceReminders::Notifier.send(
      :new,
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    ).send(:initialize_outcomes!)
    outcome_id = InvoiceReminderNotificationDelivery.sole.id

    @invoice.destroy!

    assert_not InvoiceReminderNotificationDelivery.exists?(outcome_id)
  end

  test "a failed retry enqueue stays pending for the recurring sweep" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "enqueue-repair@example.com"
    )
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(FakeDelivery.new(
        -> { raise Net::SMTPServerBusy, "451 retry safely" }
      ))
    InvoiceReminders::NotificationDeliveryJob.any_instance
      .stubs(:enqueue)
      .returns(false)
    Rails.logger.stubs(:error)

    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    )

    outcome = InvoiceReminderNotificationDelivery.sole
    assert_predicate outcome, :status_pending?
    assert_equal 1, outcome.scheduling_failures
    assert_empty ConversationEvent.kind_invoice_reminder_notifications_finalized

    InvoiceReminders::NotificationDeliveryJob.any_instance
      .unstub(:enqueue)
    travel_to outcome.reload.next_retry_at + 1.second do
      assert_enqueued_with(
        job: InvoiceReminders::NotificationDeliveryJob,
        args: [ outcome.id ]
      ) do
        InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
      end
    end
  end

  test "a final audit failure retries the marker without resending recipients" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "marker-retry@example.com"
    )
    sends = 0
    delivery = FakeDelivery.new(-> { sends += 1 })
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
    ConversationEvent.stubs(:record_once!)
      .raises(StandardError, "audit unavailable")

    assert_raises StandardError do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end
    assert_equal 1, sends
    assert_predicate InvoiceReminderNotificationDelivery.sole,
      :status_delivered?
    ConversationEvent.unstub(:record_once!)

    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    )
    assert_equal 1, sends
    assert_predicate ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole, :persisted?
  end

  private
    def assert_ambiguous_transport_failure(error, email:)
      create_subscriber(
        account: @invoice.account,
        event: :invoice_reminder,
        email:
      )
      InvoiceReminderNotificationMailer.stubs(:reminder_sent)
        .returns(FakeDelivery.new(-> { raise error }))
      Rails.logger.stubs(:error)

      assert_no_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob do
        InvoiceReminders::Notifier.deliver_once(
          invoice: @invoice,
          reminder: @reminder,
          terminal: false
        )
      end

      outcome = @reminder.notification_deliveries.sole
      assert_predicate outcome, :status_uncertain?
      assert_equal 1, outcome.attempts
    end

    def create_subscriber(account:, event:, email:, active: true, enabled: true)
      identity = Identity.create!(email_address: email)
      account.users.create!(
        name: email,
        identity:,
        active:,
        verified_at: Time.current
      ).tap do |user|
        user.notification_subscriptions.create!(event:, email: enabled)
      end
    end

    def replacement_reminder
      @replacement_day_offset = (@replacement_day_offset || 7) + 1
      message = @invoice.conversation_messages.create!(
        account: @invoice.account,
        conversation: Conversation.for_invoice!(invoice: @invoice),
        direction: :outbound,
        kind: :scheduled_reminder,
        status: :sent,
        sent_at: Time.current
      )
      @invoice.invoice_reminders.create!(
        account: @invoice.account,
        conversation_message: message,
        category: :pre_due,
        day_offset: @replacement_day_offset,
        stage_key: "pre_due_#{@replacement_day_offset}",
        tone: :friendly
      )
    end
end

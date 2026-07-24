require "test_helper"
require "net/smtp"

class InvoiceReminders::NotificationDeliveryJobTest < ActiveJob::TestCase
  FakeDelivery = Data.define(:callback) do
    def deliver_now
      callback.call
    end
  end
  RenderedDelivery = Data.define(:render_callback) do
    def message
      self
    end

    def encoded
      render_callback.call
    end

    def deliver_now
      raise "transport must not start after a rendering failure"
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
    @user = @invoice.account.users.create!(
      name: "Notification job",
      identity: Identity.create!(email_address: "notification-job@example.com"),
      verified_at: Time.current
    )
    @user.notification_subscriptions.create!(
      event: :invoice_reminder,
      email: true
    )
  end

  test "the real retry job delivers a transiently failed outcome once" do
    attempts = 0
    delivery = FakeDelivery.new(lambda do
      attempts += 1
      raise Net::SMTPServerBusy, "451 temporary rejection" if attempts == 1
    end)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).returns(delivery)
    Rails.logger.stubs(:error)

    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    )
    outcome = InvoiceReminderNotificationDelivery.sole

    perform_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob

    assert_equal 2, attempts
    assert_predicate outcome.reload, :status_delivered?
    assert_predicate ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole, :persisted?
  end

  test "five total transport attempts including the initial attempt exhaust once" do
    attempts = 0
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(FakeDelivery.new(lambda do
        attempts += 1
        raise Net::SMTPServerBusy, "451 still rejected"
      end))
    Rails.logger.stubs(:error)

    perform_enqueued_jobs do
      InvoiceReminders::Notifier.deliver_once(
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      )
    end

    outcome = InvoiceReminderNotificationDelivery.sole
    assert_equal 5, attempts
    assert_equal 5, outcome.reload.attempts
    assert_predicate outcome.reload, :status_failed?
    event = ConversationEvent.kind_invoice_reminder_notifications_finalized.sole
    assert_equal 1, event.metadata["failed_count"]
    assert_equal 0, event.metadata["canceled_count"]
  end

  test "queued replays cannot exceed the global attempt budget" do
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(FakeDelivery.new(
        -> { raise Net::SMTPServerBusy, "451 final rejection" }
      ))
    Rails.logger.stubs(:error)
    outcome = initialized_outcome
    outcome.update!(attempts: 4, next_retry_at: Time.current)
    owner = InvoiceReminders::NotificationDeliveryJob.new(outcome.id)
    replay = InvoiceReminders::NotificationDeliveryJob.new(outcome.id)
    assert outcome.reserve_retry!(
      job_id: owner.job_id,
      run_at: Time.current,
      at: Time.current
    )

    owner.perform_now
    replay.perform_now
    owner.perform_now

    assert_equal 5, outcome.reload.attempts
    assert_predicate outcome, :status_failed?
    assert_equal 1, ConversationEvent
      .kind_invoice_reminder_notifications_finalized.count
  end

  test "a lifecycle change before the retry cancels without another send" do
    attempts = 0
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(FakeDelivery.new(lambda do
        attempts += 1
        raise Net::SMTPServerBusy, "451 retry safely"
      end))
    Rails.logger.stubs(:error)
    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    )
    outcome = InvoiceReminderNotificationDelivery.sole
    @user.deactivate

    perform_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob

    assert_equal 1, attempts
    assert_predicate outcome.reload, :status_canceled?
    event = ConversationEvent.kind_invoice_reminder_notifications_finalized.sole
    assert_equal 1, event.metadata["canceled_count"]
  end

  test "a serialized job chain terminally exhausts persistent rendering failures" do
    renders = 0
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .returns(RenderedDelivery.new(lambda do
        renders += 1
        raise ActionView::Template::Error, "persistent render failure"
      end))
    Rails.logger.stubs(:error)

    InvoiceReminders::Notifier.deliver_once(
      invoice: @invoice,
      reminder: @reminder,
      terminal: false
    )
    8.times do
      serialized_job = enqueued_jobs.shift
      break unless serialized_job

      ActiveJob::Base.execute(serialized_job)
    end

    outcome = InvoiceReminderNotificationDelivery.sole.reload
    assert_equal 5, renders
    assert_equal 5, outcome.build_attempts
    assert_equal 0, outcome.attempts
    assert_predicate outcome, :status_failed?
    assert_equal "build_attempts_exhausted", outcome.terminal_reason
    assert_empty enqueued_jobs
    assert_equal 1, ConversationEvent
      .kind_invoice_reminder_notifications_finalized.count
  end

  private
    def initialized_outcome
      InvoiceReminders::Notifier.send(
        :new,
        invoice: @invoice,
        reminder: @reminder,
        terminal: false
      ).send(:initialize_outcomes!)
      InvoiceReminderNotificationDelivery.sole
    end
end

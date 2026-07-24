require "test_helper"

class ConversationMessages::EmailRecorderReconciliationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @connection = email_connections(:paid_jar_gmail)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @anchor = @conversation.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "reconcile-anchor",
      provider_thread_id: "reconcile-thread",
      internet_message_id: "<reconcile-anchor@example.com>",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 1.hour.ago,
      from_address: @invoice.customer.email,
      subject: "Question about INV-001",
      matching_status: :matched,
      matching_method: :gmail_thread
    )
    target = ConversationMessages::ManualReply.reply_target_for(
      conversation: @conversation,
      reply_to_message: @anchor
    )
    @reply = ConversationMessages::ManualReply.enqueue!(
      conversation: @conversation,
      reply_to_message: @anchor,
      actor_user: users(:arjun),
      body: "Thanks for your message.",
      idempotency_key: "reconcile-reply",
      composer_token: ConversationMessages::ManualReply.composer_token_for(
        conversation: @conversation,
        target:
      )
    )
    clear_enqueued_jobs
    @reply.refresh_delivery_attempt!(
      job_id: @reply.delivery_job_id,
      mail_message: Mail.new,
      attempted_at: 5.minutes.ago
    )
    @reply.claim_provider_delivery!(
      job_id: @reply.delivery_job_id,
      started_at: 5.minutes.ago
    )
    @reply.mark_delivery_failed!(
      job_id: @reply.delivery_job_id,
      failure_reason: ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON,
      delivery_uncertain: true
    )
    @conversation.update!(attention_required_at: @anchor.received_at)
  end

  test "Gmail SENT ingestion reconciles an unconfirmed app reply by stable RFC Message-ID" do
    ConversationMessages::ManualReplyOutcome.finalize!(@reply)
    assert_equal @anchor.received_at,
      @conversation.reload.attention_required_at
    assert_predicate @reply.conversation_events
      .kind_conversation_manual_reply_unconfirmed
      .sole,
      :actor_kind_system?

    receipt = @connection.email_message_receipts.create!(
      account: @account,
      provider_message_id: "gmail-confirmed-reply",
      discovered_at: Time.current
    )
    receipt.claim!(job_id: "reconcile-receipt")

    assert_no_difference -> { ConversationMessage.count } do
      EmailMessageReceipts::Processor.call(
        receipt,
        job_id: "reconcile-receipt",
        mailbox: FakeMailbox.new(gmail_message)
      )
    end

    @reply.reload
    assert_predicate @reply, :status_sent?
    assert_equal "gmail-confirmed-reply", @reply.provider_message_id
    assert_equal "reconcile-thread", @reply.provider_thread_id
    assert_not_predicate @reply, :delivery_uncertain?
    assert_nil @reply.failure_reason
    assert_nil @conversation.reload.attention_required_at
    assert_equal @reply, receipt.reload.conversation_message
    assert_predicate @conversation.conversation_events
      .kind_conversation_manual_reply_sent
      .sole,
      :actor_kind_system?
    assert_predicate @reply.conversation_events
      .kind_conversation_manual_reply_unconfirmed
      .sole,
      :actor_kind_system?

    parsed_message = EmailConnection::Gmail::MessageParser.call(gmail_message)
    assert_no_difference -> { @reply.conversation_events.count } do
      assert @reply.reconcile_imported_manual_reply!(
        receipt:,
        parsed_message:,
        provider_account_id: @connection.provider_account_id
      )
      ConversationMessages::ManualReplyOutcome.finalize!(@reply)
    end
    assert_nil @conversation.reload.attention_required_at
  end

  test "Gmail SENT ingestion reconciles an uncertain scheduled reminder idempotently" do
    reminder_message = uncertain_delivery_message(
      kind: :scheduled_reminder,
      internet_message_id: "<uncertain-reminder@example.com>"
    )
    reminder = @invoice.invoice_reminders.create!(
      account: @account,
      conversation_message: reminder_message,
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      tone: :friendly
    )
    receipt = process_sent_delivery(
      reminder_message,
      provider_message_id: "confirmed-scheduled-reminder"
    )

    assert_predicate reminder_message.reload, :status_sent?
    assert_predicate reminder.reload, :status_sent?
    assert_equal "confirmed-scheduled-reminder",
      reminder_message.provider_message_id
    assert_not_predicate reminder_message, :delivery_uncertain?
    event = reminder_message.conversation_events
      .kind_conversation_message_imported
      .sole
    assert event.metadata.fetch("reconciled_app_delivery")
    assert event.metadata.fetch("previously_uncertain")

    assert_no_difference [
      -> { ConversationMessage.count },
      -> { reminder_message.conversation_events.count }
    ] do
      parsed = EmailConnection::Gmail::MessageParser.call(
        gmail_message_for(
          reminder_message,
          id: "confirmed-scheduled-reminder"
        )
      )
      assert reminder_message.reconcile_imported_app_delivery!(
        receipt:,
        parsed_message: parsed,
        provider_account_id: @connection.provider_account_id
      )
    end
  end

  test "Gmail SENT ingestion repairs an uncertain promise follow-up" do
    source_message = @invoice.conversation_messages.create!(
      account: @account,
      conversation: @conversation,
      direction: :inbound,
      kind: :customer_reply,
      status: :received,
      received_at: 2.days.ago
    )
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message:,
      promised_on: Date.current - 2.days
    )
    follow_up = uncertain_delivery_message(
      kind: :promise_follow_up,
      internet_message_id: "<uncertain-promise@example.com>"
    )
    promise.update!(follow_up_message: follow_up)
    promise.follow_up_failed!

    receipt = process_sent_delivery(
      follow_up,
      provider_message_id: "confirmed-promise-follow-up"
    )

    assert_predicate follow_up.reload, :status_sent?
    assert_predicate promise.reload, :status_followed_up?
    assert_nil promise.active_invoice_id
    assert_equal follow_up, receipt.reload.conversation_message
    assert_predicate follow_up.conversation_events
      .kind_conversation_message_imported
      .sole,
      :actor_kind_system?
  end

  test "manual reminder process loss reconciles without a duplicate contact" do
    reservation = InvoiceReminders::ManualDeliveryReservation.call(
      invoice: @invoice,
      delivery_job_id: "manual-reminder-process-loss"
    )
    message = reservation.message
    assert message.claim_provider_delivery!(
      job_id: "manual-reminder-process-loss",
      started_at: 3.hours.ago
    )
    message.update!(delivery_attempted_at: 3.hours.ago)

    ConversationMessages::ReconcilePendingDeliveriesJob.perform_now

    assert_predicate message.reload, :status_failed?
    assert_predicate message, :delivery_uncertain?
    assert_no_difference -> { ConversationMessage.count } do
      process_sent_delivery(
        message,
        provider_message_id: "confirmed-manual-reminder"
      )
    end
    assert_predicate message.reload, :status_sent?
    assert_equal "confirmed-manual-reminder", message.provider_message_id

    @account.update!(automatic_invoice_reminders_enabled: true)
    automatic = InvoiceReminders::StageDecision.call(
      invoice: @invoice,
      category: :pre_due,
      day_offset: 7,
      on: Date.new(2026, 7, 24)
    )
    assert_equal "recent_outbound_message", automatic.reason
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @anchor,
      promised_on: Date.current - 1.day
    )
    promise_decision = PaymentPromises::FollowUpDecision.for_delivery(
      payment_promise: promise,
      delivery_job_id: "promise-after-manual-reminder"
    )
    assert_equal "recent_outbound_message", promise_decision.reason

    operator_reservation = InvoiceReminders::ManualDeliveryReservation.call(
      invoice: @invoice,
      delivery_job_id: "manual-reminder-operator-override"
    )
    assert_predicate operator_reservation, :reserved?
    assert_equal operator_reservation.message,
      InvoiceReminders::ManualDeliveryReservation.call(
        invoice: @invoice,
        delivery_job_id: "manual-reminder-operator-override"
      ).message
    assert_equal 2, @invoice.conversation_messages.kind_manual_reminder.count
  end

  test "promise reconciliation rolls back fully and a retry repairs it" do
    source_message = @invoice.conversation_messages.create!(
      account: @account,
      conversation: @conversation,
      direction: :inbound,
      kind: :customer_reply,
      status: :received,
      received_at: 2.days.ago
    )
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message:,
      promised_on: Date.current - 2.days
    )
    follow_up = uncertain_delivery_message(
      kind: :promise_follow_up,
      internet_message_id: "<atomic-promise@example.com>"
    )
    promise.update!(follow_up_message: follow_up)
    promise.follow_up_failed!
    receipt = @connection.email_message_receipts.create!(
      account: @account,
      provider_message_id: "atomic-promise-confirmation",
      discovered_at: Time.current
    )
    receipt.claim!(job_id: "atomic-promise-job")
    gmail = gmail_message_for(
      follow_up,
      id: "atomic-promise-confirmation"
    )
    PaymentPromise.any_instance
      .stubs(:confirm_imported_follow_up!)
      .raises(EmailConnection::Errors::TemporaryProviderError, "crash window")

    assert_raises EmailConnection::Errors::TemporaryProviderError do
      EmailMessageReceipts::Processor.call(
        receipt,
        job_id: "atomic-promise-job",
        mailbox: FakeMailbox.new(gmail)
      )
    end

    PaymentPromise.any_instance.unstub(:confirm_imported_follow_up!)
    assert_predicate receipt.reload, :status_processing?
    assert_predicate follow_up.reload, :status_failed?
    assert_predicate promise.reload, :status_follow_up_failed?

    assert_no_difference -> { ConversationMessage.count } do
      assert_difference -> { follow_up.conversation_events.count }, 1 do
        EmailMessageReceipts::Processor.call(
          receipt,
          job_id: "atomic-promise-job",
          mailbox: FakeMailbox.new(gmail)
        )
      end
    end

    assert_no_difference -> { follow_up.conversation_events.count } do
      follow_up.reconcile_imported_app_delivery!(
        receipt:,
        parsed_message: EmailConnection::Gmail::MessageParser.call(gmail),
        provider_account_id: @connection.provider_account_id
      )
    end

    assert_predicate receipt.reload, :status_processed?
    assert_predicate follow_up.reload, :status_sent?
    assert_predicate promise.reload, :status_followed_up?
  ensure
    PaymentPromise.any_instance.unstub(:confirm_imported_follow_up!)
  end

  test "eventual scheduled reminder confirmation notifies only once" do
    reminder_message = uncertain_delivery_message(
      kind: :scheduled_reminder,
      internet_message_id: "<eventual-reminder@example.com>"
    )
    reminder = @invoice.invoice_reminders.create!(
      account: @account,
      conversation_message: reminder_message,
      invoice_schedule: invoice_schedules(:normal_pre_due_7),
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      tone: :friendly
    )
    InvoiceReminders::Notifier.expects(:deliver).with(
      invoice: @invoice,
      reminder:,
      terminal: false
    ).once

    receipt = process_sent_delivery(
      reminder_message,
      provider_message_id: "eventual-reminder-confirmed"
    )
    parsed = EmailConnection::Gmail::MessageParser.call(
      gmail_message_for(
        reminder_message,
        id: "eventual-reminder-confirmed"
      )
    )
    assert reminder_message.reconcile_imported_app_delivery!(
      receipt:,
      parsed_message: parsed,
      provider_account_id: @connection.provider_account_id
    )
  end

  test "repeated Gmail SENT repair retries only a known-failed notification" do
    user = users(:arjun)
    user.update!(
      identity: Identity.create!(
        email_address: "gmail-notification-repair@example.com"
      ),
      verified_at: Time.current
    )
    user.notification_subscriptions.create!(
      event: :invoice_reminder,
      email: true
    )
    reminder_message = uncertain_delivery_message(
      kind: :scheduled_reminder,
      internet_message_id: "<gmail-notification-repair@example.com>"
    )
    reminder = @invoice.invoice_reminders.create!(
      account: @account,
      conversation_message: reminder_message,
      invoice_schedule: invoice_schedules(:normal_pre_due_7),
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      tone: :friendly,
      terminal_at_delivery: false
    )
    InvoiceReminderNotificationMailer.stubs(:reminder_sent)
      .raises(StandardError, "known notification failure")
    Rails.logger.stubs(:error)

    process_sent_delivery(
      reminder_message,
      provider_message_id: "gmail-notification-repair"
    )
    assert_predicate reminder.notification_deliveries.sole, :status_pending?
    assert_empty ConversationEvent.kind_invoice_reminder_notifications_finalized
    InvoiceReminderNotificationMailer.unstub(:reminder_sent)

    assert_no_emails do
      ConversationMessages::EmailRecorder.finalize_existing_delivery!(
        reminder_message.reload
      )
    end
    assert_emails 1 do
      perform_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob
    end
    assert_predicate reminder.notification_deliveries.sole.reload,
      :status_delivered?

    assert_no_emails do
      2.times do
        ConversationMessages::EmailRecorder.finalize_existing_delivery!(
          reminder_message.reload
        )
      end
    end
    assert_predicate ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole, :persisted?
  end

  test "eventual terminal reminder confirmation sends both notification outcomes once" do
    reminder_message = uncertain_delivery_message(
      kind: :scheduled_reminder,
      internet_message_id: "<eventual-terminal@example.com>"
    )
    reminder = @invoice.invoice_reminders.create!(
      account: @account,
      conversation_message: reminder_message,
      invoice_schedule: invoice_schedules(:normal_overdue_14),
      category: :overdue,
      day_offset: 14,
      stage_key: "overdue_14",
      tone: :final
    )
    InvoiceReminders::Notifier.expects(:deliver).with(
      invoice: @invoice,
      reminder:,
      terminal: true
    ).once

    receipt = process_sent_delivery(
      reminder_message,
      provider_message_id: "eventual-terminal-confirmed"
    )
    parsed = EmailConnection::Gmail::MessageParser.call(
      gmail_message_for(
        reminder_message,
        id: "eventual-terminal-confirmed"
      )
    )
    assert reminder_message.reconcile_imported_app_delivery!(
      receipt:,
      parsed_message: parsed,
      provider_account_id: @connection.provider_account_id
    )
  end

  test "eventual confirmation keeps terminal intent after a later stage is added" do
    reminder_message = uncertain_delivery_message(
      kind: :scheduled_reminder,
      internet_message_id: "<terminal-snapshot-kept@example.com>"
    )
    reminder = @invoice.invoice_reminders.create!(
      account: @account,
      conversation_message: reminder_message,
      invoice_schedule: invoice_schedules(:normal_overdue_14),
      category: :overdue,
      day_offset: 14,
      stage_key: "overdue_14",
      tone: :final,
      terminal_at_delivery: true
    )
    @account.invoice_schedules.create!(
      kind: @invoice.customer.payer_segment,
      category: :overdue,
      day_offset: 21,
      tone: :final
    )
    InvoiceReminders::Notifier.expects(:deliver).with(
      invoice: @invoice,
      reminder:,
      terminal: true
    ).once

    process_sent_delivery(
      reminder_message,
      provider_message_id: "terminal-snapshot-kept"
    )
  end

  test "eventual confirmation stays nonterminal after later stages are removed" do
    reminder_message = uncertain_delivery_message(
      kind: :scheduled_reminder,
      internet_message_id: "<nonterminal-snapshot-kept@example.com>"
    )
    stage = invoice_schedules(:normal_overdue_3)
    reminder = @invoice.invoice_reminders.create!(
      account: @account,
      conversation_message: reminder_message,
      invoice_schedule: stage,
      category: :overdue,
      day_offset: 3,
      stage_key: "overdue_3",
      tone: :direct,
      terminal_at_delivery: false
    )
    @account.invoice_schedules.where(
      kind: @invoice.customer.payer_segment,
      category: :overdue
    ).where("day_offset > ?", stage.day_offset).delete_all
    InvoiceReminders::Notifier.expects(:deliver).with(
      invoice: @invoice,
      reminder:,
      terminal: false
    ).once

    process_sent_delivery(
      reminder_message,
      provider_message_id: "nonterminal-snapshot-kept"
    )
  end

  test "eventual confirmation keeps terminal intent after customer resegmentation" do
    reminder_message = uncertain_delivery_message(
      kind: :scheduled_reminder,
      internet_message_id: "<terminal-segment-snapshot@example.com>"
    )
    reminder = @invoice.invoice_reminders.create!(
      account: @account,
      conversation_message: reminder_message,
      invoice_schedule: invoice_schedules(:normal_overdue_14),
      category: :overdue,
      day_offset: 14,
      stage_key: "overdue_14",
      tone: :final,
      terminal_at_delivery: true
    )
    @invoice.customer.update!(
      customer_segment: customer_segments(:bad_debtor_segment)
    )
    InvoiceReminders::Notifier.expects(:deliver).with(
      invoice: @invoice,
      reminder:,
      terminal: true
    ).once

    process_sent_delivery(
      reminder_message,
      provider_message_id: "terminal-segment-snapshot"
    )
  end

  private
    def gmail_message
      gmail_message_for(@reply, id: "gmail-confirmed-reply")
    end

    def gmail_message_for(delivery, id:)
      Google::Apis::GmailV1::Message.new(
        id:,
        thread_id: "reconcile-thread",
        internal_date: (Time.current.to_f * 1000).to_i.to_s,
        label_ids: [ "SENT" ],
        payload: Google::Apis::GmailV1::MessagePart.new(
          mime_type: "text/plain",
          headers: {
            "From" => @connection.connected_email,
            "To" => @invoice.customer.email,
            "Subject" => "Re: Question about INV-001",
            "Message-ID" => delivery.internet_message_id,
            "In-Reply-To" => @anchor.internet_message_id,
            "References" => @anchor.internet_message_id
          }.map do |name, value|
            Google::Apis::GmailV1::MessagePartHeader.new(name:, value:)
          end,
          body: Google::Apis::GmailV1::MessagePartBody.new(
            data: delivery.body
          )
        )
      )
    end

    def uncertain_delivery_message(kind:, internet_message_id:)
      @invoice.conversation_messages.create!(
        account: @account,
        conversation: @conversation,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        direction: :outbound,
        kind:,
        status: :failed,
        delivery_attempted_at: 10.minutes.ago,
        provider_delivery_started_at: 10.minutes.ago,
        failure_reason: "Provider response lost.",
        delivery_uncertain: true,
        internet_message_id:,
        from_address: @connection.connected_email,
        to_addresses: [ @invoice.customer.email ],
        subject: "Invoice #{@invoice.number}",
        body: "Please review the invoice."
      )
    end

    def process_sent_delivery(delivery, provider_message_id:)
      receipt = @connection.email_message_receipts.create!(
        account: @account,
        provider_message_id:,
        discovered_at: Time.current
      )
      receipt.claim!(job_id: "reconcile-#{provider_message_id}")
      assert_no_difference -> { ConversationMessage.count } do
        EmailMessageReceipts::Processor.call(
          receipt,
          job_id: "reconcile-#{provider_message_id}",
          mailbox: FakeMailbox.new(
            gmail_message_for(delivery, id: provider_message_id)
          )
        )
      end
      receipt
    end

    class FakeMailbox
      def initialize(message)
        @message = message
      end

      def message(id:)
        raise "unexpected message" unless id == @message.id

        @message
      end
    end
end

require "test_helper"

class InvoiceReminders::ReconcileNotificationDeliveriesJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    invoice = invoices(:xero_invoice)
    message = invoice.conversation_messages.create!(
      account: invoice.account,
      conversation: Conversation.for_invoice!(invoice:),
      direction: :outbound,
      kind: :scheduled_reminder,
      status: :sent,
      sent_at: Time.current
    )
    @reminder = invoice.invoice_reminders.create!(
      account: invoice.account,
      conversation_message: message,
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      tone: :friendly
    )
    user = invoice.account.users.create!(
      name: "Notification sweep",
      identity: Identity.create!(email_address: "notification-sweep@example.com"),
      verified_at: Time.current
    )
    @outcome = @reminder.notification_deliveries.create!(
      account: invoice.account,
      recipient_user: user,
      recipient_user_snapshot_id: user.id,
      recipient_email: user.identity.email_address,
      event_name: "invoice_reminder"
    )
    @reminder.update!(
      notifications_initialized_at: Time.current,
      terminal_at_delivery: false
    )
  end

  test "the sweep initializes notification work lost after the reminder was sent" do
    @outcome.destroy!
    @reminder.update_columns(
      notifications_initialized_at: nil,
      notifications_finalized_at: nil
    )
    user = @reminder.account.users.create!(
      name: "Lost notification initialization",
      identity: Identity.create!(
        email_address: "lost-notification-initialization@example.com"
      ),
      verified_at: Time.current
    )
    user.notification_subscriptions.create!(
      event: :invoice_reminder,
      email: true
    )

    assert_emails 1 do
      InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
    end

    assert @reminder.reload.notifications_initialized_at
    assert @reminder.notifications_finalized_at
    assert_predicate @reminder.notification_deliveries.sole,
      :status_delivered?
    assert_predicate ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole, :persisted?
  end

  test "the sweep re-enqueues orphaned pending work after process loss" do
    assert_enqueued_with(
      job: InvoiceReminders::NotificationDeliveryJob,
      args: [ @outcome.id ]
    ) do
      InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
    end
    assert_predicate @outcome.reload, :status_pending?
    assert @outcome.retry_job_id
    assert @outcome.retry_enqueued_at
    assert @outcome.next_retry_at
  end

  test "repeated sweeps leave one owned retry in the queue" do
    assert_enqueued_jobs 1,
      only: InvoiceReminders::NotificationDeliveryJob do
      2.times do
        InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
      end
    end

    assert @outcome.reload.retry_job_id
  end

  test "a recent queued retry is not duplicated even after it becomes due" do
    owner = InvoiceReminders::NotificationDeliveryJob.new(@outcome.id)
    @outcome.update!(next_retry_at: 1.minute.ago)
    assert @outcome.reserve_retry!(
      job_id: owner.job_id,
      run_at: @outcome.next_retry_at,
      at: Time.current
    )

    assert_no_enqueued_jobs only: InvoiceReminders::NotificationDeliveryJob do
      InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
    end

    assert_equal owner.job_id, @outcome.reload.retry_job_id
  end

  test "a stale enqueue reservation is released and replaced once" do
    abandoned = InvoiceReminders::NotificationDeliveryJob.new(@outcome.id)
    @outcome.update!(next_retry_at: 1.minute.ago)
    assert @outcome.reserve_retry!(
      job_id: abandoned.job_id,
      run_at: @outcome.next_retry_at,
      at: InvoiceReminderNotificationDelivery::RETRY_RESERVATION_STALE_AFTER.ago -
        1.second
    )

    assert_enqueued_jobs 1,
      only: InvoiceReminders::NotificationDeliveryJob do
      InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
    end

    assert_not_equal abandoned.job_id, @outcome.reload.retry_job_id
  end

  test "the sweep makes a stale claim uncertain and creates the terminal audit" do
    @outcome.claim_for_delivery!(
      attempt_token: "lost-process",
      at: InvoiceReminderNotificationDelivery::STALE_AFTER.ago - 1.second
    )

    InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now

    assert_predicate @outcome.reload, :status_uncertain?
    assert_predicate ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole, :persisted?
  end

  test "an enqueue failure remains visible and recoverable to the next sweep" do
    InvoiceReminders::NotificationDeliveryJob.any_instance
      .stubs(:enqueue)
      .returns(false)
    Rails.logger.stubs(:error)

    InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now

    assert_predicate @outcome.reload, :status_pending?
    assert_equal "ActiveJob::EnqueueError", @outcome.last_error_class
    assert_equal 1, @outcome.scheduling_failures
    assert_nil @outcome.retry_job_id
    assert_nil @outcome.retry_enqueued_at
  end

  %i[delivered uncertain failed canceled].each do |terminal_status|
    test "the sweep repairs a missing #{terminal_status} audit without resending" do
      make_terminal(terminal_status)
      InvoiceReminderNotificationMailer.expects(:reminder_sent).never
      ConversationEvent.stubs(:record_once!)
        .raises(StandardError, "audit unavailable")

      assert_nothing_raised do
        InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
      end
      assert_empty ConversationEvent
        .kind_invoice_reminder_notifications_finalized
      assert_nil @reminder.reload.notifications_finalized_at
      ConversationEvent.unstub(:record_once!)

      2.times do
        InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
      end

      assert_equal 1, ConversationEvent
        .kind_invoice_reminder_notifications_finalized.count
      assert @reminder.reload.notifications_finalized_at
      assert_predicate @outcome.reload, :"status_#{terminal_status}?"
    end
  end

  test "the sweep repairs a zero-recipient audit failure" do
    @outcome.destroy!
    ConversationEvent.stubs(:record_once!)
      .raises(StandardError, "audit unavailable")

    assert_nothing_raised do
      InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now
    end
    assert_nil @reminder.reload.notifications_finalized_at
    ConversationEvent.unstub(:record_once!)

    2.times { InvoiceReminders::ReconcileNotificationDeliveriesJob.perform_now }

    event = ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole
    assert_equal 0, event.metadata["delivered_count"]
    assert @reminder.reload.notifications_finalized_at
  end

  test "recurring reconciliation queries have eligible shape-matched indexes" do
    job = InvoiceReminders::ReconcileNotificationDeliveriesJob.new

    assert_index_columns(
      :invoice_reminders,
      "index_invoice_reminders_on_notification_state",
      %w[notifications_finalized_at notifications_initialized_at]
    )
    assert_index_columns(
      :invoice_reminder_notification_deliveries,
      "index_reminder_notification_deliveries_on_due_retry",
      %w[status retry_job_id next_retry_at]
    )
    assert_index_columns(
      :invoice_reminder_notification_deliveries,
      "index_reminder_notification_deliveries_on_stale_retry",
      %w[status retry_enqueued_at retry_job_id]
    )

    assert_explain_candidate(
      job.send(:uninitialized_reminders),
      "index_invoice_reminders_on_notification_state"
    )
    assert_explain_candidate(
      job.send(:initialized_unfinalized_reminders),
      "index_invoice_reminders_on_notification_state"
    )
    assert_explain_candidate(
      job.send(:due_unowned_outcomes),
      "index_reminder_notification_deliveries_on_due_retry"
    )
    assert_explain_candidate(
      job.send(:stale_retry_reservations, before: Time.current),
      "index_reminder_notification_deliveries_on_stale_retry"
    )
  end

  private
    def make_terminal(status)
      attributes = {
        status:,
        attempt_token: nil,
        delivery_started_at: Time.current
      }
      attributes[:delivered_at] = Time.current if status == :delivered
      attributes[:failed_at] = Time.current if status == :failed
      attributes[:canceled_at] = Time.current if status == :canceled
      @outcome.update_columns(attributes)
    end

    def assert_index_columns(table, name, expected_columns)
      index = ActiveRecord::Base.connection.indexes(table)
        .find { |candidate| candidate.name == name }

      assert index, "Expected #{name} on #{table}"
      assert_equal expected_columns, index.columns
    end

    def assert_explain_candidate(relation, index_name)
      plan = ActiveRecord::Base.connection.exec_query(
        "EXPLAIN #{relation.limit(1_000).to_sql}"
      )
      candidates = plan.flat_map do |row|
        row.fetch("possible_keys", "").to_s.split(",")
      end

      assert_includes candidates, index_name
    end
end

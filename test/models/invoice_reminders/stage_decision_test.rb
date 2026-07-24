require "test_helper"

class InvoiceReminders::StageDecisionTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @invoice.account.update!(automatic_invoice_reminders_enabled: true)
  end

  test "returns the current stage and email connection when delivery is allowed" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      decision = decide

      assert_predicate decision, :deliverable?
      assert_equal invoice_schedules(:normal_pre_due_7), decision.stage
      assert_equal email_connections(:paid_jar_gmail), decision.connection
      assert_nil decision.reminder
      assert_nil decision.reason
    end
  end

  test "returns the email connection configuration reason" do
    @invoice.account.email_connection.destroy!

    decision = decide

    assert_not_predicate decision, :deliverable?
    assert_equal "missing_email_connection", decision.reason
  end

  test "rejects a disabled account and a paid invoice" do
    @invoice.account.update!(automatic_invoice_reminders_enabled: false)
    assert_equal "disabled_account", decide.reason

    @invoice.account.update!(automatic_invoice_reminders_enabled: true)
    @invoice.update!(status: :paid, amount_due: 0, paid_on: Date.current)
    assert_equal "not_outstanding", decide.reason
  end

  test "uses the customer's current payer segment to find the stage" do
    decision = decide(category: :overdue, day_offset: 99)

    assert_equal "stage_not_in_current_schedule", decision.reason
    assert_equal @invoice.customer.payer_segment, decision.context.fetch(:payer_segment)
  end

  test "rejects a stage that is already suppressed or delivered" do
    stage = invoice_schedules(:normal_pre_due_7)
    InvoiceReminderSuppression.record_for!(
      invoice: @invoice,
      stage:,
      reason: :recent_outbound_message
    )
    assert_equal "suppressed_stage", decide.reason

    @invoice.invoice_reminder_suppressions.delete_all
    create_reminder(stage:, status: :failed)
    assert_equal "duplicate_stage", decide.reason
  end

  test "allows the job that owns an existing pending delivery to retry it" do
    stage = invoice_schedules(:normal_pre_due_7)
    reminder = create_reminder(stage:, status: :pending, delivery_job_id: "retry-job")

    travel_to Time.zone.local(2026, 7, 24, 12) do
      decision = decide(delivery_job_id: "retry-job")

      assert_predicate decision, :deliverable?
      assert_equal reminder, decision.reminder
    end
  end

  test "allows an owned pending delivery to retry after midnight" do
    stage = invoice_schedules(:normal_pre_due_7)
    reminder = nil

    travel_to Time.zone.local(2026, 7, 24, 23, 59) do
      reminder = create_reminder(stage:, status: :pending, delivery_job_id: "retry-job")
    end

    travel_to Time.zone.local(2026, 7, 25, 0, 1) do
      decision = decide(delivery_job_id: "retry-job")

      assert_predicate decision, :deliverable?
      assert_equal reminder, decision.reminder
    end
  end

  test "rejects an owned retry when the due date invalidates its reservation date" do
    stage = invoice_schedules(:normal_pre_due_7)

    travel_to Time.zone.local(2026, 7, 24, 23, 59) do
      create_reminder(stage:, status: :pending, delivery_job_id: "retry-job")
    end
    @invoice.update!(due_on: @invoice.due_on + 2.days)

    travel_to Time.zone.local(2026, 7, 25, 0, 1) do
      assert_equal "stage_not_due", decide(delivery_job_id: "retry-job").reason
    end
  end

  test "checks the due date and customer recipient" do
    travel_to Time.zone.local(2026, 7, 23, 12) do
      assert_equal "stage_not_due", decide.reason
    end

    travel_to Time.zone.local(2026, 7, 24, 12) do
      @invoice.customer.update!(email: nil)
      decision = decide

      assert_equal "missing_email", decision.reason
      assert_equal @invoice.customer_id, decision.context.fetch(:customer_id)
    end
  end

  test "returns durable suppression reasons for promises and recent contact" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      promise = create_payment_promise
      decision = decide

      assert_predicate decision, :suppression?
      assert_equal "active_payment_promise", decision.reason

      promise.cancel!
      create_message(
        kind: :invoice_resend,
        status: :sent,
        sent_at: 1.hour.ago,
        provider_message_id: "recent-contact"
      )
      decision = decide

      assert_predicate decision, :suppression?
      assert_equal "recent_outbound_message", decision.reason
    end
  end

  test "returns active collection hold as a durable suppression with safe context" do
    hold = place_hold

    travel_to Time.zone.local(2026, 7, 24, 12) do
      @invoice.customer.update!(email: nil)
      decision = decide

      assert_predicate decision, :suppression?
      assert_equal "active_collection_hold", decision.reason
      assert_equal [ hold.id ], decision.context.fetch(:collection_hold_ids)
      assert_equal [ "dispute" ], decision.context.fetch(:collection_hold_reasons)
      refute_includes decision.context.values, hold.note
    end
  end

  private
    def decide(category: :pre_due, day_offset: 7, delivery_job_id: nil)
      InvoiceReminders::StageDecision.call(
        invoice: @invoice.reload,
        category:,
        day_offset:,
        delivery_job_id:
      )
    end

    def create_reminder(stage:, status:, delivery_job_id: nil)
      message = create_message(status:, delivery_job_id:)
      @invoice.invoice_reminders.create!(
        account: @invoice.account,
        conversation_message: message,
        invoice_schedule: stage,
        category: stage.category,
        day_offset: stage.day_offset,
        stage_key: stage.key,
        tone: stage.tone
      )
    end

    def create_message(
      direction: :outbound,
      kind: :scheduled_reminder,
      status:,
      sent_at: nil,
      received_at: nil,
      provider_message_id: nil,
      delivery_job_id: nil
    )
      @invoice.conversation_messages.create!(
        account: @invoice.account,
        conversation: Conversation.for_invoice!(invoice: @invoice),
        direction:,
        kind:,
        status:,
        sent_at:,
        received_at:,
        provider_message_id:,
        delivery_job_id:,
        delivery_attempted_at: delivery_job_id.present? ? Time.current : nil,
        from_address: "billing@paymentreminder.example",
        to_addresses: [ "customer@example.com" ],
        cc_addresses: [],
        subject: "Invoice INV-001",
        body: "Payment reminder"
      )
    end

    def create_payment_promise
      source_message = create_message(
        direction: :inbound,
        kind: :customer_reply,
        status: :received,
        received_at: Time.current,
        provider_message_id: "promise-stage-decision"
      )
      PaymentPromise.record!(
        invoice: @invoice,
        source_message:,
        promised_on: Date.current + 2.days
      )
    end

    def place_hold
      CollectionHolds::Placement.call(
        conversation: Conversation.for_invoice!(invoice: @invoice),
        reason: :dispute,
        note: "Private dispute detail",
        placed_by_kind: :user,
        placed_by_user: users(:arjun),
        idempotency_key: "stage-decision-hold"
      )
    end
end

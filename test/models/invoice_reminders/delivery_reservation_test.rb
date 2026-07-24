require "test_helper"

class InvoiceReminders::DeliveryReservationTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @invoice.account.update!(automatic_invoice_reminders_enabled: true)
  end

  test "atomically reserves a pending message and reminder from the current stage" do
    travel_to reminder_time do
      assert_difference [
        -> { @invoice.conversation_messages.count },
        -> { @invoice.invoice_reminders.count }
      ], 1 do
        @reservation = reserve
      end
    end

    assert_predicate @reservation, :reserved?
    assert_equal invoice_schedules(:normal_pre_due_7), @reservation.stage
    assert_equal email_connections(:paid_jar_gmail), @reservation.connection
    assert_equal "Upcoming Payment Due: Invoice INV-001", @reservation.mail_message.subject

    assert_not_predicate @reservation.reminder, :terminal_at_delivery?
    message = @reservation.reminder.conversation_message
    assert_equal Conversation.for_invoice!(invoice: @invoice), message.conversation
    assert_predicate message, :status_pending?
    assert_predicate message, :kind_scheduled_reminder?
    assert_equal "delivery-job-123", message.delivery_job_id
    assert_equal @reservation.connection, message.email_connection
    assert_equal @reservation.connection.provider_account_id, message.provider_account_id
    assert_equal @reservation.connection.credential_generation, message.email_connection_generation
    assert_match(/\A<.+@paymentreminder\.local>\z/, message.internet_message_id)
    assert_equal [ "customer@example.com" ], message.to_addresses
    assert_match "friendly reminder", message.body
  end

  test "snapshots terminal intent when the reminder is reserved" do
    travel_to Time.zone.local(2026, 8, 14, 12) do
      reservation = InvoiceReminders::DeliveryReservation.call(
        invoice: @invoice.reload,
        category: :overdue,
        day_offset: 14,
        delivery_job_id: "terminal-snapshot-job"
      )

      assert_predicate reservation, :reserved?
      assert_predicate reservation.reminder, :terminal_at_delivery?
      assert_raises ActiveRecord::RecordInvalid do
        reservation.reminder.update!(terminal_at_delivery: false)
      end
    end
  end

  test "does not reuse a pending reminder after the Gmail identity is replaced" do
    travel_to reminder_time do
      first = reserve
      first.connection.update!(provider_account_id: "replacement-google-account")

      replacement = reserve

      assert_not_predicate replacement, :reserved?
      assert_equal "email_connection_replaced", replacement.reason
    end
  end

  test "does not reuse a pending reminder after the same Gmail identity reconnects" do
    travel_to reminder_time do
      first = reserve
      first.connection.increment!(:credential_generation)

      replacement = reserve

      assert_not_predicate replacement, :reserved?
      assert_equal "email_connection_replaced", replacement.reason
    end
  end

  test "reuses only the pending delivery owned by the same job" do
    travel_to reminder_time do
      first = reserve

      assert_no_difference -> { @invoice.conversation_messages.count } do
        assert_no_difference -> { @invoice.invoice_reminders.count } do
          second = reserve

          assert_predicate second, :reserved?
          assert_equal first.reminder, second.reminder
          assert_equal first.reminder.conversation_message.internet_message_id,
            second.reminder.conversation_message.internet_message_id
        end
      end

      foreign_job = reserve(delivery_job_id: "another-job")
      assert_not_predicate foreign_job, :reserved?
      assert_equal "duplicate_stage", foreign_job.reason
    end
  end

  test "returns the authoritative locked eligibility decision without creating delivery" do
    @invoice.update!(status: :paid, amount_due: 0, paid_on: Date.current)

    assert_no_difference -> { @invoice.conversation_messages.count } do
      @reservation = reserve
    end

    assert_not_predicate @reservation, :reserved?
    assert_equal "not_outstanding", @reservation.reason
  end

  test "persists a durable suppression instead of reserving delivery" do
    travel_to reminder_time do
      create_recent_message

      assert_difference -> { @invoice.invoice_reminder_suppressions.count }, 1 do
        @reservation = reserve
      end
    end

    assert_not_predicate @reservation, :reserved?
    assert_equal "recent_outbound_message", @reservation.reason
    assert_predicate @invoice.invoice_reminder_suppressions.last,
      :reason_recent_outbound_message?
  end

  test "a hold under the invoice lock suppresses the stage without reserving delivery" do
    place_hold

    travel_to reminder_time do
      assert_difference -> { @invoice.invoice_reminder_suppressions.count }, 1 do
        assert_no_difference -> { @invoice.invoice_reminders.count } do
          @reservation = reserve
        end
      end
    end

    assert_equal "active_collection_hold", @reservation.reason
    assert_predicate @invoice.invoice_reminder_suppressions.last,
      :reason_active_collection_hold?
  end

  test "does not reserve while another outbound delivery is pending" do
    @invoice.conversation_messages.create!(
      account: @invoice.account,
      conversation: Conversation.for_invoice!(invoice: @invoice),
      direction: :outbound,
      kind: :invoice_resend,
      status: :pending,
      delivery_job_id: "invoice-resend-job",
      delivery_attempted_at: Time.current,
      from_address: "billing@paymentreminder.example",
      to_addresses: [ "customer@example.com" ],
      cc_addresses: [],
      subject: "Invoice INV-001",
      body: "Here is the invoice."
    )

    travel_to reminder_time do
      assert_no_difference -> { @invoice.invoice_reminders.count } do
        @reservation = reserve
      end
    end

    assert_not_predicate @reservation, :reserved?
    assert_equal "outbound_delivery_in_progress", @reservation.reason
  end

  private
    def reserve(delivery_job_id: "delivery-job-123")
      InvoiceReminders::DeliveryReservation.call(
        invoice: @invoice.reload,
        category: :pre_due,
        day_offset: 7,
        delivery_job_id:
      )
    end

    def create_recent_message
      @invoice.conversation_messages.create!(
        account: @invoice.account,
        conversation: Conversation.for_invoice!(invoice: @invoice),
        direction: :outbound,
        kind: :invoice_resend,
        status: :sent,
        sent_at: 1.hour.ago,
        provider_message_id: "delivery-reservation-recent",
        from_address: "billing@paymentreminder.example",
        to_addresses: [ "customer@example.com" ],
        cc_addresses: [],
        subject: "Invoice INV-001",
        body: "Here is the invoice."
      )
    end

    def reminder_time
      Time.zone.local(2026, 7, 24, 12)
    end

    def place_hold
      CollectionHolds::Placement.call(
        conversation: Conversation.for_invoice!(invoice: @invoice),
        reason: :manual,
        placed_by_kind: :user,
        placed_by_user: users(:arjun),
        idempotency_key: "reservation-hold"
      )
    end
end

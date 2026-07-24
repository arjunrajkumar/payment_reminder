require "test_helper"

class PaymentPromises::DeliveryReservationTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @account.update!(automatic_invoice_reminders_enabled: true)
    @payment_promise = create_promise
  end

  test "atomically reserves and links an auditable follow-up message" do
    travel_to follow_up_time do
      assert_difference -> { @invoice.conversation_messages.count }, 1 do
        @reservation = reserve
      end
    end

    assert_predicate @reservation, :reserved?
    assert_equal @payment_promise.reload.follow_up_message, @reservation.message
    assert_equal Conversation.for_invoice!(invoice: @invoice), @reservation.message.conversation
    assert_predicate @reservation.message, :status_pending?
    assert_predicate @reservation.message, :kind_promise_follow_up?
    assert_equal "promise-delivery-job", @reservation.message.delivery_job_id
    assert_equal email_connections(:paid_jar_gmail), @reservation.connection
    assert_equal @reservation.connection, @reservation.message.email_connection
    assert_equal @reservation.connection.provider_account_id, @reservation.message.provider_account_id
    assert_equal @reservation.connection.credential_generation, @reservation.message.email_connection_generation
    assert_equal "Payment status: Invoice INV-001", @reservation.mail_message.subject
  end

  test "does not reuse a pending follow-up after the Gmail identity is replaced" do
    travel_to follow_up_time do
      first = reserve
      first.connection.update!(provider_account_id: "replacement-google-account")

      replacement = reserve

      assert_not_predicate replacement, :reserved?
      assert_equal "email_connection_replaced", replacement.reason
    end
  end

  test "does not reuse a pending follow-up after the same Gmail identity reconnects" do
    travel_to follow_up_time do
      first = reserve
      first.connection.increment!(:credential_generation)

      replacement = reserve

      assert_not_predicate replacement, :reserved?
      assert_equal "email_connection_replaced", replacement.reason
    end
  end

  test "reuses only the pending follow-up owned by the same job" do
    travel_to follow_up_time do
      first = reserve

      assert_no_difference -> { @invoice.conversation_messages.count } do
        second = reserve
        assert_predicate second, :reserved?
        assert_equal first.message, second.message
      end

      foreign_job = reserve(delivery_job_id: "other-job")
      assert_not_predicate foreign_job, :reserved?
      assert_equal "outbound_delivery_in_progress", foreign_job.reason
    end
  end

  test "an owned retry is cancelled when another confirmed contact is newer" do
    travel_to follow_up_time do
      first = reserve
      recent = create_contact(
        status: :sent,
        sent_at: 1.hour.ago,
        provider_message_id: "newer-confirmed-contact"
      )

      retry_result = reserve

      assert_not_predicate retry_result, :reserved?
      assert_equal "recent_outbound_message", retry_result.reason
      assert_predicate first.message.reload, :status_failed?
      assert_nil @payment_promise.reload.follow_up_message
      assert_predicate @payment_promise, :status_active?
      assert_predicate recent, :status_sent?
    end
  end

  test "an owned retry is cancelled when another uncertain contact is newer" do
    travel_to follow_up_time do
      first = reserve
      create_contact(
        status: :failed,
        delivery_uncertain: true,
        provider_delivery_started_at: 1.hour.ago,
        failure_reason: "Provider response was lost."
      )

      retry_result = reserve

      assert_not_predicate retry_result, :reserved?
      assert_equal "recent_outbound_message", retry_result.reason
      assert_predicate first.message.reload, :status_failed?
      assert_nil @payment_promise.reload.follow_up_message
      assert_predicate @payment_promise, :status_active?
    end
  end

  test "an owned retry is allowed at the exact cooldown boundary" do
    travel_to follow_up_time do
      first = reserve
      create_contact(
        status: :sent,
        sent_at: 48.hours.ago,
        provider_message_id: "boundary-confirmed-contact"
      )

      retry_result = reserve

      assert_predicate retry_result, :reserved?
      assert_equal first.message, retry_result.message
    end
  end

  test "a foreign job cannot cancel another job's pending follow-up" do
    travel_to follow_up_time do
      first = reserve
      create_contact(
        status: :sent,
        sent_at: 1.hour.ago,
        provider_message_id: "foreign-job-newer-contact"
      )

      foreign = reserve(delivery_job_id: "foreign-job")

      assert_not_predicate foreign, :reserved?
      assert_equal "outbound_delivery_in_progress", foreign.reason
      assert_predicate first.message.reload, :status_pending?
      assert_equal first.message, @payment_promise.reload.follow_up_message
    end
  end

  test "authoritatively resolves a paid promise instead of reserving delivery" do
    @invoice.update!(status: :paid, amount_due: 0, paid_on: Date.current)

    travel_to follow_up_time do
      assert_no_difference -> { @invoice.conversation_messages.count } do
        @reservation = reserve
      end
    end

    assert_predicate @reservation, :resolved?
    assert_equal :fulfilled, @reservation.resolution
    assert_predicate @payment_promise.reload, :status_fulfilled?
  end

  test "returns eligibility reasons without reserving delivery" do
    @account.update!(automatic_invoice_reminders_enabled: false)

    travel_to follow_up_time do
      assert_no_difference -> { @invoice.conversation_messages.count } do
        @reservation = reserve
      end
    end

    assert_not_predicate @reservation, :reserved?
    assert_equal "disabled_account", @reservation.reason
    assert_predicate @payment_promise.reload, :status_active?
  end

  test "does not reserve or resolve an active promise while collection is held" do
    place_hold

    travel_to follow_up_time do
      assert_no_difference -> { @invoice.conversation_messages.count } do
        @reservation = reserve
      end
    end

    assert_equal "active_collection_hold", @reservation.reason
    assert_predicate @payment_promise.reload, :status_active?
    assert_nil @payment_promise.follow_up_message
  end

  private
    def reserve(delivery_job_id: "promise-delivery-job")
      PaymentPromises::DeliveryReservation.call(
        payment_promise: @payment_promise.reload,
        delivery_job_id:
      )
    end

    def create_promise
      PaymentPromise.record!(
        invoice: @invoice,
        source_message: @invoice.conversation_messages.create!(
          account: @account,
          conversation: Conversation.for_invoice!(invoice: @invoice),
          direction: :inbound,
          kind: :customer_reply,
          status: :received,
          received_at: Time.current,
          provider_message_id: "delivery-reservation-promise-source",
          from_address: "customer@example.com",
          to_addresses: [ "billing@paymentreminder.example" ],
          cc_addresses: [],
          subject: "Re: Invoice INV-001",
          body: "I will pay on August 3."
        ),
        promised_on: Date.new(2026, 8, 3)
      )
    end

    def create_contact(
      status:,
      sent_at: nil,
      provider_message_id: nil,
      delivery_uncertain: false,
      provider_delivery_started_at: nil,
      failure_reason: nil
    )
      @invoice.conversation_messages.create!(
        account: @account,
        conversation: Conversation.for_invoice!(invoice: @invoice),
        direction: :outbound,
        kind: :invoice_resend,
        status:,
        sent_at:,
        provider_message_id:,
        delivery_uncertain:,
        provider_delivery_started_at:,
        failure_reason:,
        from_address: "billing@paymentreminder.example",
        to_addresses: [ "customer@example.com" ],
        cc_addresses: [],
        subject: "Invoice INV-001",
        body: "Here is the invoice."
      )
    end

    def follow_up_time
      Time.zone.local(2026, 8, 4, 9)
    end

    def place_hold
      CollectionHolds::Placement.call(
        conversation: Conversation.for_invoice!(invoice: @invoice),
        reason: :manual,
        placed_by_kind: :user,
        placed_by_user: users(:arjun),
        idempotency_key: "promise-reservation-hold"
      )
    end
end

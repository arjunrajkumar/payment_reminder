require "test_helper"

class PaymentPromises::FollowUpDecisionTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @account.update!(automatic_invoice_reminders_enabled: true)
    @payment_promise = create_promise
  end

  test "allows a due outstanding promise to proceed to invoice refresh" do
    @account.update!(automatic_invoice_reminders_enabled: false)

    travel_to follow_up_time do
      decision = PaymentPromises::FollowUpDecision.before_refresh(
        payment_promise: @payment_promise
      )

      assert_predicate decision, :ready?
      assert_nil decision.connection
    end
  end

  test "returns the resolution represented by existing terminal delivery" do
    message = create_follow_up_message(status: :failed, failure_reason: "Delivery failed")
    @payment_promise.update!(follow_up_message: message)

    travel_to follow_up_time do
      decision = PaymentPromises::FollowUpDecision.before_refresh(
        payment_promise: @payment_promise
      )

      assert_predicate decision, :resolvable?
      assert_equal :follow_up_failed, decision.resolution
    end
  end

  test "returns fulfilled or cancelled when no delivery is needed" do
    travel_to follow_up_time do
      @invoice.update!(status: :paid, amount_due: 0, paid_on: Date.current)
      assert_equal :fulfilled, before_refresh.resolution

      @invoice.update!(status: :uncollectible, paid_on: nil)
      assert_equal :cancelled, before_refresh.resolution
    end
  end

  test "checks delivery settings recipients and recent contact only at delivery time" do
    travel_to follow_up_time do
      @account.update!(automatic_invoice_reminders_enabled: false)
      assert_equal "disabled_account", for_delivery.reason

      @account.update!(automatic_invoice_reminders_enabled: true)
      @invoice.customer.update!(email: nil)
      assert_equal "missing_email", for_delivery.reason

      @invoice.customer.update!(email: "customer@example.com")
      create_sent_message
      assert_equal "recent_outbound_message", for_delivery.reason
    end
  end

  test "allows only the job that owns a pending follow-up to resume it" do
    message = create_follow_up_message(
      status: :pending,
      delivery_job_id: "owner-job",
      delivery_attempted_at: Time.current
    )
    @payment_promise.update!(follow_up_message: message)

    travel_to follow_up_time do
      assert_equal "outbound_delivery_in_progress", for_delivery(delivery_job_id: "other-job").reason

      decision = for_delivery(delivery_job_id: "owner-job")
      assert_predicate decision, :ready?
      assert_equal message, decision.message
      assert_equal email_connections(:paid_jar_gmail), decision.connection
    end
  end

  test "an active hold pauses before refresh and again at locked delivery" do
    hold = place_hold

    travel_to follow_up_time do
      preflight = before_refresh
      delivery = for_delivery

      assert_equal "active_collection_hold", preflight.reason
      assert_equal "active_collection_hold", delivery.reason
      assert_equal [ hold.id ], preflight.context.fetch(:collection_hold_ids)
      assert_predicate @payment_promise.reload, :status_active?
    end
  end

  private
    def before_refresh
      PaymentPromises::FollowUpDecision.before_refresh(payment_promise: @payment_promise.reload)
    end

    def for_delivery(delivery_job_id: "delivery-job")
      PaymentPromises::FollowUpDecision.for_delivery(
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
          provider_message_id: "follow-up-decision-source",
          from_address: "customer@example.com",
          to_addresses: [ "billing@paymentreminder.example" ],
          cc_addresses: [],
          subject: "Re: Invoice INV-001",
          body: "I will pay on August 3."
        ),
        promised_on: Date.new(2026, 8, 3)
      )
    end

    def create_follow_up_message(attributes)
      @invoice.conversation_messages.create!(
        {
          account: @account,
          conversation: Conversation.for_invoice!(invoice: @invoice),
          direction: :outbound,
          kind: :promise_follow_up,
          from_address: "billing@paymentreminder.example",
          to_addresses: [ "customer@example.com" ],
          cc_addresses: [],
          subject: "Payment status: Invoice INV-001",
          body: "Could you confirm the payment status?"
        }.merge(attributes)
      )
    end

    def create_sent_message
      create_follow_up_message(
        kind: :invoice_resend,
        status: :sent,
        sent_at: 1.hour.ago,
        provider_message_id: "recent-follow-up-decision"
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
        idempotency_key: "follow-up-decision-hold"
      )
    end
end

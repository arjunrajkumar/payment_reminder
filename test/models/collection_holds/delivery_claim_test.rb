require "test_helper"

class CollectionHolds::DeliveryClaimTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @account.update!(automatic_invoice_reminders_enabled: true)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @actor = users(:arjun)
  end

  test "a hold placed after reminder reservation cancels the owned unsent delivery" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      reservation = InvoiceReminders::DeliveryReservation.call(
        invoice: @invoice,
        category: :pre_due,
        day_offset: 7,
        delivery_job_id: "reminder-owner"
      )
      hold = place_hold("reminder-final-hold")

      claim = InvoiceReminders::FinalDeliveryClaim.call(
        invoice: @invoice,
        reminder: reservation.reminder,
        delivery_job_id: "reminder-owner"
      )

      assert_not_predicate claim, :claimed?
      assert_equal "active_collection_hold", claim.reason
      assert_equal [ hold.id ], claim.context.fetch(:collection_hold_ids)
      assert_predicate reservation.reminder.conversation_message.reload, :status_failed?
      suppression = @invoice.invoice_reminder_suppressions.find_by!(
        stage_key: "pre_due_7"
      )
      assert_predicate suppression, :reason_active_collection_hold?
    end
  end

  test "a reminder claim that wins before hold placement is durably recorded" do
    reservation = nil
    travel_to Time.zone.local(2026, 7, 24, 12) do
      reservation = InvoiceReminders::DeliveryReservation.call(
        invoice: @invoice,
        category: :pre_due,
        day_offset: 7,
        delivery_job_id: "reminder-winner"
      )
    end
    message = reservation.reminder.conversation_message

    assert_predicate InvoiceReminders::FinalDeliveryClaim.call(
      invoice: @invoice,
      reminder: reservation.reminder,
      delivery_job_id: "reminder-winner"
    ), :claimed?
    hold = place_hold("hold-after-reminder-claim")

    assert message.reload.provider_delivery_started_at
    assert_equal [ message.id ], hold.in_flight_delivery_message_ids
    refute_predicate InvoiceReminders::FinalDeliveryClaim.call(
      invoice: @invoice,
      reminder: reservation.reminder,
      delivery_job_id: "reminder-winner"
    ), :claimed?
    assert_equal hold, place_hold("hold-after-reminder-claim")
  end

  test "a held retry-owned promise delivery is detached without failing the promise" do
    promise = create_promise
    reservation = nil
    travel_to follow_up_time do
      reservation = PaymentPromises::DeliveryReservation.call(
        payment_promise: promise,
        delivery_job_id: "promise-owner"
      )
    end
    hold = place_hold("promise-final-hold")

    claim = PaymentPromises::FinalDeliveryClaim.call(
      payment_promise: promise,
      message: reservation.message,
      delivery_job_id: "promise-owner"
    )

    assert_not_predicate claim, :claimed?
    assert_equal "active_collection_hold", claim.reason
    assert_predicate reservation.message.reload, :status_failed?
    assert_predicate promise.reload, :status_active?
    assert_nil promise.follow_up_message

    release_hold(hold)
    travel_to follow_up_time do
      replacement = PaymentPromises::DeliveryReservation.call(
        payment_promise: promise,
        delivery_job_id: "replacement-owner"
      )
      assert_predicate replacement, :reserved?
      refute_equal reservation.message, replacement.message
      assert_predicate PaymentPromises::FinalDeliveryClaim.call(
        payment_promise: promise,
        message: replacement.message,
        delivery_job_id: "replacement-owner"
      ), :claimed?
    end
  end

  test "a newer contact after reservation cancels before promise provider handoff" do
    promise = create_promise
    reservation = nil
    travel_to follow_up_time do
      reservation = PaymentPromises::DeliveryReservation.call(
        payment_promise: promise,
        delivery_job_id: "promise-contact-race"
      )
      @invoice.conversation_messages.create!(
        account: @account,
        conversation: @conversation,
        direction: :outbound,
        kind: :invoice_resend,
        status: :sent,
        sent_at: 1.minute.ago,
        provider_message_id: "contact-after-promise-reservation",
        from_address: "billing@paymentreminder.example",
        to_addresses: [ "customer@example.com" ],
        cc_addresses: [],
        subject: "Invoice INV-001",
        body: "Here is the invoice."
      )

      claim = PaymentPromises::FinalDeliveryClaim.call(
        payment_promise: promise,
        message: reservation.message,
        delivery_job_id: "promise-contact-race"
      )

      assert_not_predicate claim, :claimed?
      assert_equal "recent_outbound_message", claim.reason
    end
    assert_predicate reservation.message.reload, :status_failed?
    assert_predicate promise.reload, :status_active?
    assert_nil promise.follow_up_message
  end

  test "a claimed promise delivery survives hold cleanup and finalizes once" do
    promise = create_promise
    reservation = nil
    travel_to follow_up_time do
      reservation = PaymentPromises::DeliveryReservation.call(
        payment_promise: promise,
        delivery_job_id: "promise-in-flight"
      )
    end
    assert_predicate PaymentPromises::FinalDeliveryClaim.call(
      payment_promise: promise,
      message: reservation.message,
      delivery_job_id: "promise-in-flight"
    ), :claimed?
    hold = place_hold("hold-after-promise-claim")

    blocked_retry = PaymentPromises::FinalDeliveryClaim.call(
      payment_promise: promise,
      message: reservation.message,
      delivery_job_id: "promise-in-flight"
    )
    assert_equal "delivery_already_in_flight", blocked_retry.reason
    assert_equal [ reservation.message.id ], hold.in_flight_delivery_message_ids

    assert promise.record_follow_up_sent!(
      job_id: "promise-in-flight",
      provider_message_id: "accepted-once"
    )
    assert_predicate reservation.message.reload, :status_sent?
    assert_predicate promise.reload, :status_followed_up?
  end

  test "an accepted but unfinalized promise remains uncertain and never duplicates" do
    promise = create_promise
    reservation = nil
    travel_to follow_up_time do
      reservation = PaymentPromises::DeliveryReservation.call(
        payment_promise: promise,
        delivery_job_id: "crashed-after-accept"
      )
      PaymentPromises::FinalDeliveryClaim.call(
        payment_promise: promise,
        message: reservation.message,
        delivery_job_id: "crashed-after-accept"
      )
    end
    hold = place_hold("hold-after-provider-accept")

    travel_to follow_up_time + 3.hours do
      assert reservation.message.reconcile_stale_delivery!(
        before: 2.hours.ago,
        failure_reason: "Delivery confirmation timed out."
      )
    end

    assert_predicate reservation.message.reload, :status_failed?
    assert_predicate reservation.message, :delivery_uncertain?
    assert_equal reservation.message, promise.reload.follow_up_message
    assert_predicate promise, :status_follow_up_failed?

    release_hold(hold)
    assert_no_difference -> { @invoice.conversation_messages.count } do
      travel_to follow_up_time + 4.hours do
        PaymentPromises::FollowUpJob.perform_now(promise.id)
      end
    end
  end

  test "hold release between preflight and cleanup cancels the definitely unsent reservation" do
    promise = create_promise
    reservation = nil
    travel_to follow_up_time do
      reservation = PaymentPromises::DeliveryReservation.call(
        payment_promise: promise,
        delivery_job_id: "released-during-pause"
      )
    end
    hold = place_hold("transient-hold")
    release_hold(hold)

    result = PaymentPromises::HoldPause.call(
      payment_promise: promise,
      delivery_job_id: "released-during-pause"
    )

    assert_equal "delivery_cancelled", result.reason
    assert_predicate reservation.message.reload, :status_failed?
    assert_nil promise.reload.follow_up_message
    assert_predicate promise, :status_active?
  end

  private
    def create_promise
      PaymentPromise.record!(
        invoice: @invoice,
        source_message: @invoice.conversation_messages.create!(
          account: @account,
          conversation: @conversation,
          direction: :inbound,
          kind: :customer_reply,
          status: :received,
          received_at: Time.current,
          from_address: @invoice.customer.email
        ),
        promised_on: Date.new(2026, 8, 3)
      )
    end

    def place_hold(idempotency_key)
      CollectionHolds::Placement.call(
        conversation: @conversation,
        reason: :manual,
        placed_by_kind: :user,
        placed_by_user: @actor,
        idempotency_key:
      )
    end

    def release_hold(hold)
      idempotency_key = "release-#{hold.id}"
      hold.release!(
        actor_user: @actor,
        idempotency_key:,
        snapshot_token: CollectionHolds::HoldSnapshot.token_for(
          hold:,
          idempotency_key:
        )
      )
    end

    def follow_up_time
      Time.zone.local(2026, 8, 4, 9)
    end
end

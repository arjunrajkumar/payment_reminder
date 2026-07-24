require "test_helper"

class PaymentPromises::FollowUpJobTest < ActiveJob::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @account.update!(automatic_invoice_reminders_enabled: true)
    @payment_promise = create_promise
    @delivery_result = EmailConnection::Delivery::Result.new(
      provider_message_id: "promise-follow-up-message",
      provider_thread_id: "promise-follow-up-thread"
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver).returns(@delivery_result)
  end

  test "limits concurrency to one job for each payment promise" do
    first_job = PaymentPromises::FollowUpJob.new(@payment_promise.id)
    same_promise_job = PaymentPromises::FollowUpJob.new(@payment_promise.id)
    other_promise_job = PaymentPromises::FollowUpJob.new(@payment_promise.id + 1)

    assert_predicate first_job, :concurrency_limited?
    assert_equal "PaymentPromises::FollowUpJob/#{@payment_promise.id}", first_job.concurrency_key
    assert_equal first_job.concurrency_key, same_promise_job.concurrency_key
    refute_equal first_job.concurrency_key, other_promise_job.concurrency_key
  end

  test "refreshes an outstanding invoice and sends one auditable follow-up" do
    travel_to follow_up_time do
      assert_difference -> { @invoice.conversation_messages.count }, 1 do
        PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
      end
    end

    message = @payment_promise.reload.follow_up_message
    assert_predicate @payment_promise, :status_followed_up?
    assert_predicate message, :direction_outbound?
    assert_predicate message, :kind_promise_follow_up?
    assert_predicate message, :status_sent?
    assert_equal follow_up_time, message.sent_at
    assert_equal "promise-follow-up-message", message.provider_message_id
    assert_equal "promise-follow-up-thread", message.provider_thread_id
    assert_equal "billing@paymentreminder.example", message.from_address
    assert_equal [ "customer@example.com" ], message.to_addresses
    assert_equal [], message.cc_addresses
    assert_equal "Payment status: Invoice INV-001", message.subject
    assert_match "Could you confirm the payment status?", message.body
  end

  test "duplicate jobs do not send the follow-up twice" do
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).once.returns(@delivery_result)

    travel_to follow_up_time do
      assert_difference -> { @invoice.conversation_messages.count }, 1 do
        2.times { PaymentPromises::FollowUpJob.perform_now(@payment_promise.id) }
      end
    end

    assert_predicate @payment_promise.reload, :status_followed_up?
  end

  test "marks a paid invoice fulfilled without sending" do
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).with do |invoice|
      @invoice.update!(status: :paid, amount_due: 0, paid_on: Date.new(2026, 8, 3))
      invoice == @invoice
    end.returns(@invoice)
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).never

    travel_to follow_up_time do
      assert_no_difference -> { @invoice.conversation_messages.count } do
        PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
      end
    end

    assert_predicate @payment_promise.reload, :status_fulfilled?
  end

  test "marks a locally paid invoice fulfilled without refreshing" do
    @invoice.update!(status: :paid, amount_due: 0, paid_on: Date.new(2026, 8, 3))
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).never

    travel_to follow_up_time do
      PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
    end

    assert_predicate @payment_promise.reload, :status_fulfilled?
  end

  test "cancels follow-up when the refreshed invoice is no longer collectible" do
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).with do |invoice|
      @invoice.update!(status: :uncollectible)
      invoice == @invoice
    end.returns(@invoice)

    travel_to follow_up_time do
      PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
    end

    assert_predicate @payment_promise.reload, :status_cancelled?
    assert_nil @payment_promise.follow_up_message
  end

  test "waits when another successful outbound message was sent within 48 hours" do
    create_outbound_message(sent_at: follow_up_time - 1.hour)
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).never

    travel_to follow_up_time do
      assert_no_difference -> { @invoice.conversation_messages.count } do
        PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
      end
    end

    assert_predicate @payment_promise.reload, :status_active?
    assert_nil @payment_promise.follow_up_message
  end

  test "allows follow-up when the previous outbound message is exactly 48 hours old" do
    create_outbound_message(sent_at: follow_up_time - 48.hours)

    travel_to follow_up_time do
      assert_difference -> { @invoice.conversation_messages.count }, 1 do
        PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
      end
    end

    assert_predicate @payment_promise.reload, :status_followed_up?
  end

  test "rechecks account settings before reserving delivery" do
    @account.update!(automatic_invoice_reminders_enabled: false)
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).with(@invoice).returns(@invoice)
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).never

    travel_to follow_up_time do
      assert_no_difference -> { @invoice.conversation_messages.count } do
        PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
      end
    end

    assert_predicate @payment_promise.reload, :status_active?
  end

  test "a collection hold pauses before provider refresh and leaves the promise active" do
    place_hold("promise-job-hold")
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).never
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).never

    travel_to follow_up_time do
      assert_no_difference -> { @invoice.conversation_messages.count } do
        PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
      end
    end

    assert_predicate @payment_promise.reload, :status_active?
    assert_nil @payment_promise.follow_up_message
  end

  test "a hold detaches an owned unsent retry and release permits one replacement" do
    job = PaymentPromises::FollowUpJob.new(@payment_promise.id)
    pending = create_pending_follow_up(delivery_job_id: job.job_id)
    hold = place_hold("promise-retry-hold")
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).never

    travel_to follow_up_time do
      job.perform_now
    end

    assert_predicate pending.reload, :status_failed?
    assert_predicate @payment_promise.reload, :status_active?
    assert_nil @payment_promise.follow_up_message

    release_hold(hold)
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).once
      .returns(@delivery_result)
    travel_to follow_up_time do
      PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
    end

    assert_predicate @payment_promise.reload, :status_followed_up?
    refute_equal pending, @payment_promise.follow_up_message
  end

  test "resolves a remotely paid promise even when Gmail is unavailable" do
    @account.update!(automatic_invoice_reminders_enabled: false)
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).with do |invoice|
      @invoice.update!(status: :paid, amount_due: 0, paid_on: Date.new(2026, 8, 3))
      invoice == @invoice
    end.returns(@invoice)
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).never

    travel_to follow_up_time do
      PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
    end

    assert_predicate @payment_promise.reload, :status_fulfilled?
  end

  test "retries a provider refresh failure without reserving delivery" do
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call)
      .raises(InvoiceSources::Xero::OauthClient::Error, "Xero unavailable")

    travel_to follow_up_time do
      assert_enqueued_jobs 1, only: PaymentPromises::FollowUpJob do
        assert_no_difference -> { @invoice.conversation_messages.count } do
          PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
        end
      end
    end

    assert_predicate @payment_promise.reload, :status_active?
  end

  test "temporary Gmail failure retries with one pending message" do
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver)
      .raises(EmailConnection::Errors::TemporaryDeliveryError, "rate limited")

    travel_to follow_up_time do
      assert_enqueued_jobs 1, only: PaymentPromises::FollowUpJob do
        assert_difference -> { @invoice.conversation_messages.count }, 1 do
          PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
        end
      end
    end

    message = @payment_promise.reload.follow_up_message
    assert_predicate @payment_promise, :status_active?
    assert_predicate message, :status_pending?
    assert message.delivery_job_id.present?
  end

  test "a retry-safe provider error relinquishes the claim and the retry sends" do
    attempts = sequence("promise-retry-safe-provider-error")
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver)
      .in_sequence(attempts)
      .raises(EmailConnection::Errors::TemporaryDeliveryError, "rate limited")
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver)
      .in_sequence(attempts)
      .returns(@delivery_result)

    travel_to follow_up_time do
      perform_enqueued_jobs(only: PaymentPromises::FollowUpJob) do
        PaymentPromises::FollowUpJob.perform_later(@payment_promise.id)
      end
    end

    assert_predicate @payment_promise.reload, :status_followed_up?
    assert_predicate @payment_promise.follow_up_message, :status_sent?
  end

  test "a temporary-delivery retry reuses its owned pending message" do
    job = PaymentPromises::FollowUpJob.new(@payment_promise.id)
    message = create_pending_follow_up(delivery_job_id: job.job_id)

    travel_to follow_up_time do
      assert_no_difference -> { @invoice.conversation_messages.count } do
        job.perform_now
      end
    end

    assert_equal message, @payment_promise.reload.follow_up_message
    assert_predicate message.reload, :status_sent?
    assert_predicate @payment_promise, :status_followed_up?
  end

  test "exhausted temporary Gmail retries fail the message and release the promise" do
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver)
      .raises(EmailConnection::Errors::TemporaryDeliveryError, "Gmail unavailable")
    job = PaymentPromises::FollowUpJob.new(@payment_promise.id)
    job.exception_executions[
      [ EmailConnection::Errors::TemporaryDeliveryError ].to_s
    ] = 4

    travel_to follow_up_time do
      assert_no_enqueued_jobs only: PaymentPromises::FollowUpJob do
        job.perform_now
      end
    end

    message = @payment_promise.reload.follow_up_message
    assert_predicate message, :status_failed?
    assert_equal "Gmail unavailable", message.failure_reason
    assert_predicate @payment_promise, :status_follow_up_failed?
    assert_nil @payment_promise.active_invoice_id
  end

  test "exhausted freshness retries fail an existing pending follow-up" do
    job = PaymentPromises::FollowUpJob.new(@payment_promise.id)
    message = create_pending_follow_up(delivery_job_id: job.job_id)
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call)
      .raises(InvoiceSources::Xero::OauthClient::Error, "Xero unavailable")
    job.exception_executions[
      [
        InvoiceReminders::InvoiceFreshnessCheck::Error,
        InvoiceSources::Xero::OauthClient::Error,
        InvoiceSources::Stripe::ApiClient::Error
      ].to_s
    ] = 4

    travel_to follow_up_time do
      assert_raises InvoiceSources::Xero::OauthClient::Error do
        job.perform_now
      end
    end

    assert_predicate message.reload, :status_failed?
    assert_equal "Xero unavailable", message.failure_reason
    assert_predicate @payment_promise.reload, :status_follow_up_failed?
  end

  test "a duplicate job does not bypass a pending delivery retry" do
    message = create_pending_follow_up(delivery_job_id: "another-job")
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).never

    travel_to follow_up_time do
      PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
    end

    assert_predicate message.reload, :status_pending?
    assert_predicate @payment_promise.reload, :status_active?
  end

  test "a permanent Gmail failure records a terminal failed follow-up" do
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver)
      .raises(EmailConnection::Errors::PermanentDeliveryError, "invalid recipient")

    travel_to follow_up_time do
      assert_no_enqueued_jobs only: PaymentPromises::FollowUpJob do
        PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
      end
    end

    message = @payment_promise.reload.follow_up_message
    assert_predicate @payment_promise, :status_follow_up_failed?
    assert_predicate message, :status_failed?
    assert_equal "invalid recipient", message.failure_reason
  end

  test "an ambiguous Gmail failure is not retried" do
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver)
      .raises(EmailConnection::Errors::AmbiguousDeliveryError, "response lost")

    travel_to follow_up_time do
      assert_no_enqueued_jobs only: PaymentPromises::FollowUpJob do
        PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
      end
    end

    message = @payment_promise.reload.follow_up_message
    assert_predicate @payment_promise, :status_follow_up_failed?
    assert_predicate message, :status_failed?
    assert_equal "response lost", message.failure_reason
  end

  test "does not record delivery as sent without a provider message ID" do
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver).returns(
      EmailConnection::Delivery::Result.new(
        provider_message_id: nil,
        provider_thread_id: "unconfirmed-thread"
      )
    )

    travel_to follow_up_time do
      PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
    end

    message = @payment_promise.reload.follow_up_message
    assert_predicate @payment_promise, :status_follow_up_failed?
    assert_predicate message, :status_failed?
    assert_equal "Email provider did not confirm delivery.", message.failure_reason
    assert_nil message.provider_thread_id
  end

  test "reconciles a stale failed follow-up message into the promise state" do
    message = create_pending_follow_up(delivery_job_id: "crashed-job")
    message.update!(status: :failed, failure_reason: "Delivery confirmation timed out.")
    @account.update!(automatic_invoice_reminders_enabled: false)
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).never
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).never

    travel_to follow_up_time do
      PaymentPromises::FollowUpJob.perform_now(@payment_promise.id)
    end

    assert_predicate @payment_promise.reload, :status_follow_up_failed?
  end

  private
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
          provider_message_id: "promise-follow-up-source",
          from_address: "customer@example.com",
          to_addresses: [ "billing@paymentreminder.example" ],
          cc_addresses: [],
          subject: "Re: Invoice INV-001",
          body: "I will pay on August 3."
        ),
        promised_on: Date.new(2026, 8, 3)
      )
    end

    def create_outbound_message(sent_at:)
      @invoice.conversation_messages.create!(
        account: @account,
        conversation: Conversation.for_invoice!(invoice: @invoice),
        direction: :outbound,
        kind: :invoice_resend,
        status: :sent,
        sent_at:,
        provider_message_id: "outbound-#{sent_at.to_i}",
        from_address: "billing@paymentreminder.example",
        to_addresses: [ "customer@example.com" ],
        cc_addresses: [],
        subject: "Invoice INV-001",
        body: "Here is the invoice."
      )
    end

    def create_pending_follow_up(delivery_job_id:)
      @invoice.conversation_messages.create!(
        account: @account,
        conversation: Conversation.for_invoice!(invoice: @invoice),
        direction: :outbound,
        kind: :promise_follow_up,
        status: :pending,
        delivery_job_id:,
        delivery_attempted_at: Time.current,
        from_address: "billing@paymentreminder.example",
        to_addresses: [ "customer@example.com" ],
        cc_addresses: [],
        subject: "Payment status: Invoice INV-001",
        body: "Could you confirm the payment status?"
      ).tap do |message|
        @payment_promise.update!(follow_up_message: message)
      end
    end

    def follow_up_time
      Time.zone.local(2026, 8, 4, 9)
    end

    def place_hold(idempotency_key)
      CollectionHolds::Placement.call(
        conversation: Conversation.for_invoice!(invoice: @invoice),
        reason: :manual,
        placed_by_kind: :user,
        placed_by_user: users(:arjun),
        idempotency_key:
      )
    end

    def release_hold(hold)
      idempotency_key = "release-#{hold.id}"
      hold.release!(
        actor_user: users(:arjun),
        idempotency_key:,
        snapshot_token: CollectionHolds::HoldSnapshot.token_for(
          hold:,
          idempotency_key:
        )
      )
    end
end

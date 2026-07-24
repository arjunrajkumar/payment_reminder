require "test_helper"

class ConversationMessages::ManualReplyJobTest < ActiveJob::TestCase
  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @connection = email_connections(:paid_jar_gmail)
    @anchor = @conversation.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "job-anchor",
      provider_thread_id: "job-thread",
      internet_message_id: "<job-anchor@example.com>",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      from_address: @invoice.customer.email,
      subject: "Question",
      matching_status: :matched,
      matching_method: :gmail_thread
    )
    @conversation.update!(attention_required_at: @anchor.received_at)
  end

  test "confirmed delivery records the provider thread and clears attention" do
    ConversationMessages::ProviderDelivery.expects(:call).returns(
      ConversationMessages::ProviderDelivery::Result.new(
        provider_message_id: "sent-reply",
        provider_thread_id: "job-thread",
        failure_reason: nil,
        delivery_uncertain: false
      )
    )

    perform_enqueued_jobs do
      @message = enqueue_reply("job-confirmed")
    end

    assert_predicate @message.reload, :status_sent?
    assert_equal "sent-reply", @message.provider_message_id
    assert_equal "job-thread", @message.provider_thread_id
    assert_nil @conversation.reload.attention_required_at
    assert_predicate @conversation.conversation_events
      .kind_conversation_manual_reply_sent
      .sole,
      :actor_kind_system?
  end

  test "a human reply still queues and delivers while automated collection is held" do
    hold = CollectionHolds::Placement.call(
      conversation: @conversation,
      reason: :dispute,
      placed_by_kind: :user,
      placed_by_user: users(:arjun),
      idempotency_key: "manual-reply-during-hold"
    )
    ConversationMessages::ProviderDelivery.expects(:call).returns(
      ConversationMessages::ProviderDelivery::Result.new(
        provider_message_id: "held-manual-reply",
        provider_thread_id: "job-thread",
        failure_reason: nil,
        delivery_uncertain: false
      )
    )

    perform_enqueued_jobs do
      @message = enqueue_reply("held-manual-reply")
    end

    assert_predicate @message.reload, :status_sent?
    assert_predicate hold.reload, :status_active?
  end

  test "unconfirmed delivery remains attention work" do
    ConversationMessages::ProviderDelivery.expects(:call).returns(
      ConversationMessages::ProviderDelivery::Result.new(
        provider_message_id: nil,
        provider_thread_id: nil,
        failure_reason: "response lost",
        delivery_uncertain: true
      )
    )

    perform_enqueued_jobs do
      @message = enqueue_reply("job-unconfirmed")
    end

    assert_predicate @message.reload, :status_failed?
    assert_predicate @message, :delivery_uncertain?
    assert @message.provider_delivery_started_at
    assert_equal ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON,
      @message.failure_reason
    assert @conversation.reload.attention_required_at
    assert_predicate @conversation.conversation_events
      .kind_conversation_manual_reply_unconfirmed
      .sole,
      :actor_kind_system?
  end

  test "an uncertain reply cools scheduled reminders through but not at 48 hours" do
    @account.update!(automatic_invoice_reminders_enabled: true)
    attempted_at = Time.zone.local(2026, 7, 24, 12)
    message = deliver_uncertain_reply(at: attempted_at, key: "reply-stage-cooldown")
    assert_equal attempted_at, message.provider_delivery_started_at

    travel_to attempted_at + 47.hours + 59.minutes do
      assert_equal "recent_outbound_message",
        scheduled_decision.reason
    end
    travel_to attempted_at + 48.hours do
      assert_predicate scheduled_decision, :deliverable?
    end
  end

  test "an uncertain reply cools promise follow-up through but not at 48 hours" do
    @account.update!(automatic_invoice_reminders_enabled: true)
    attempted_at = Time.zone.local(2026, 7, 24, 12)
    message = deliver_uncertain_reply(at: attempted_at, key: "reply-promise-cooldown")
    promise = PaymentPromise.record!(
      invoice: @invoice,
      source_message: @anchor,
      promised_on: Date.new(2026, 7, 23)
    )

    travel_to attempted_at + 47.hours + 59.minutes do
      decision = PaymentPromises::FollowUpDecision.for_delivery(
        payment_promise: promise.reload,
        delivery_job_id: "promise-after-reply",
        on: Date.new(2026, 7, 24)
      )
      assert_equal "recent_outbound_message", decision.reason
    end
    travel_to attempted_at + 48.hours do
      decision = PaymentPromises::FollowUpDecision.for_delivery(
        payment_promise: promise.reload,
        delivery_job_id: "promise-after-reply",
        on: Date.new(2026, 7, 24)
      )
      assert_predicate decision, :ready?
    end
    assert_predicate message.reload, :delivery_uncertain?
  end

  test "confirmed delivery does not clear attention from a newer inbound message" do
    ConversationMessages::ProviderDelivery.expects(:call).returns(
      ConversationMessages::ProviderDelivery::Result.new(
        provider_message_id: "sent-before-newer-inbound",
        provider_thread_id: "job-thread",
        failure_reason: nil,
        delivery_uncertain: false
      )
    )
    message = enqueue_reply("job-newer-inbound")
    newer_inbound = @conversation.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "newer-job-inbound",
      provider_thread_id: "job-thread",
      internet_message_id: "<newer-job-inbound@example.com>",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 1.minute.from_now,
      from_address: @invoice.customer.email,
      matching_status: :matched,
      matching_method: :gmail_thread
    )
    @conversation.update!(attention_required_at: newer_inbound.received_at)

    perform_enqueued_jobs

    assert_predicate message.reload, :status_sent?
    assert_equal newer_inbound.received_at,
      @conversation.reload.attention_required_at
  end

  test "re-entry repairs missing sent audit and attention without sending twice" do
    ConversationMessages::ProviderDelivery.expects(:call).once.returns(
      ConversationMessages::ProviderDelivery::Result.new(
        provider_message_id: "sent-before-finalization-failure",
        provider_thread_id: "job-thread",
        failure_reason: nil,
        delivery_uncertain: false
      )
    )
    message = enqueue_reply("repair-sent-outcome")
    ConversationEvent.stubs(:record_once!).raises(RuntimeError, "event store unavailable")

    assert_raises RuntimeError do
      perform_enqueued_jobs
    end

    assert_predicate message.reload, :status_sent?
    assert_empty message.conversation_events.kind_conversation_manual_reply_sent
    assert @conversation.reload.attention_required_at
    ConversationEvent.unstub(:record_once!)

    ConversationMessages::ManualReplyJob.perform_now(
      @account.id,
      message.id,
      message.requested_provider_thread_id
    )

    assert_predicate message.conversation_events
      .kind_conversation_manual_reply_sent
      .sole,
      :actor_kind_system?
    assert_nil @conversation.reload.attention_required_at
  end

  test "provider replacement after a prior claim preserves uncertainty" do
    original_provider_account_id = @connection.provider_account_id
    message = enqueue_reply("claimed-before-provider-replacement")
    assert message.claim_provider_delivery!(
      job_id: message.delivery_job_id,
      started_at: Time.zone.local(2026, 7, 24, 12)
    )
    @connection.update!(provider_account_id: "replacement-provider-account")

    perform_enqueued_jobs

    @connection.update!(provider_account_id: original_provider_account_id)
    assert_claim_aware_failure(message)
  end

  test "Gmail disconnection after a prior claim preserves uncertainty" do
    message = enqueue_reply("claimed-before-disconnection")
    assert message.claim_provider_delivery!(
      job_id: message.delivery_job_id,
      started_at: Time.zone.local(2026, 7, 24, 12)
    )
    @connection.disconnect!

    perform_enqueued_jobs

    restore_connection!
    assert_claim_aware_failure(message)
  end

  private
    def assert_claim_aware_failure(message)
      assert_predicate message.reload, :status_failed?
      assert_predicate message, :delivery_uncertain?
      assert_equal Time.zone.local(2026, 7, 24, 12),
        message.provider_delivery_started_at
      assert @conversation.reload.attention_required_at
      assert_predicate message.conversation_events
        .kind_conversation_manual_reply_unconfirmed
        .sole,
        :actor_kind_system?

      error = assert_raises ConversationMessages::ManualReply::StaleComposer do
        enqueue_reply("duplicate-after-claimed-#{message.id}")
      end
      assert_equal "Another reply may already have been sent for this thread.",
        error.message

      @account.update!(automatic_invoice_reminders_enabled: true)
      travel_to Time.zone.local(2026, 7, 24, 13) do
        assert_equal "recent_outbound_message", scheduled_decision.reason
        promise = PaymentPromise.record!(
          invoice: @invoice,
          source_message: @anchor,
          promised_on: Date.new(2026, 7, 23)
        )
        decision = PaymentPromises::FollowUpDecision.for_delivery(
          payment_promise: promise,
          delivery_job_id: "promise-after-claimed-reply",
          on: Date.new(2026, 7, 24)
        )
        assert_equal "recent_outbound_message", decision.reason
      end
    end

    def restore_connection!
      @connection.update!(
        status: :active,
        provider_account_id: @anchor.provider_account_id,
        access_token: "restored-access-token",
        refresh_token: "restored-refresh-token",
        token_expires_at: 1.hour.from_now,
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
      )
    end

    def deliver_uncertain_reply(at:, key:)
      ConversationMessages::ProviderDelivery.expects(:call).returns(
        ConversationMessages::ProviderDelivery::Result.new(
          provider_message_id: nil,
          provider_thread_id: nil,
          failure_reason: "response lost",
          delivery_uncertain: true
        )
      )
      travel_to at do
        perform_enqueued_jobs do
          return enqueue_reply(key).reload
        end
      end
    end

    def scheduled_decision
      InvoiceReminders::StageDecision.call(
        invoice: @invoice.reload,
        category: :pre_due,
        day_offset: 7,
        on: Date.new(2026, 7, 24)
      )
    end

    def enqueue_reply(idempotency_key)
      ConversationMessages::ManualReply.enqueue!(
        conversation: @conversation,
        reply_to_message: @anchor,
        actor_user: users(:arjun),
        body: "Thanks for your message.",
        idempotency_key:,
        composer_token: ConversationMessages::ManualReply.composer_token_for(
          conversation: @conversation,
          target: ConversationMessages::ManualReply.reply_target_for(
            conversation: @conversation,
            reply_to_message: @anchor
          )
        )
      )
    end
end

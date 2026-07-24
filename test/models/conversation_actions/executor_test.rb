require "test_helper"

class ConversationActions::ExecutorTest < ActiveJob::TestCase
  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @actor = users(:arjun)
    @connection = email_connections(:paid_jar_gmail)
    @source = create_source_message
  end

  test "refreshes and queues one immutable factual reply from normalized invoice facts" do
    action = approve_action(
      action_type: :answer_outstanding_amount,
      arguments: {},
      proposed_reply: {
        "body" => "The balance is USD 999,999.99 and is overdue."
      }
    )
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call)
      .with(@invoice)
      .returns(@invoice)

    assert_difference -> {
      ConversationMessage.kind_outstanding_amount_answer.count
    }, 1 do
      ConversationActions::Executor.call(execution: action.execution)
    end

    execution = action.execution.reload
    message = execution.conversation_message
    assert_predicate execution, :status_awaiting_delivery?
    assert_equal [ @invoice.customer.email ], message.to_addresses
    assert_empty message.cc_addresses
    assert_empty message.bcc_addresses
    assert_equal @source, message.reply_to_message
    assert_equal @source.provider_thread_id,
      message.requested_provider_thread_id
    assert_includes message.body, "USD 125.00"
    assert_not_includes message.body, "999,999.99"
    assert_no_changes -> { @invoice.collection_holds.count } do
      assert_equal message, execution.conversation_message
    end
  end

  test "a newer inbound message cancels reply reservation and opens attention" do
    action = approve_action(
      action_type: :answer_due_date,
      arguments: {}
    )
    create_source_message(
      provider_message_id: "newer-action-source",
      internet_message_id: "<newer-action-source@example.com>",
      received_at: @source.received_at + 1.minute
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)

    assert_no_difference -> { ConversationMessage.direction_outbound.count } do
      ConversationActions::Executor.call(execution: action.execution)
    end

    execution = action.execution.reload
    assert_predicate execution, :status_failed?
    assert_equal "stale_action", execution.failure_category
    assert execution.attention_required?
    assert execution.conversation_escalation
  end

  test "a payment promise remains committed when acknowledgement enqueue fails" do
    action = approve_action(
      action_type: :record_payment_promise,
      arguments: { "promised_on" => "2026-08-05" }
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationMessages::ThreadedReplyJob.any_instance
      .stubs(:enqueue)
      .returns(false)

    assert_difference -> { PaymentPromise.count }, 1 do
      ConversationActions::Executor.call(execution: action.execution)
    end

    execution = action.execution.reload
    assert execution.payment_promise.reload.status_active?
    assert_predicate execution, :status_awaiting_delivery?
    assert_predicate execution.conversation_message, :status_pending?
    assert_predicate execution.conversation_message,
      :reply_scheduling_reserved?
    assert_equal 1,
      execution.conversation_message.reply_scheduling_attempts
  end

  test "other never sends or mutates collection and requires human attention" do
    action = approve_action(
      action_type: :other,
      arguments: {},
      source_message: nil
    )

    assert_no_difference [
      -> { ConversationMessage.direction_outbound.count },
      -> { PaymentPromise.count },
      -> { CollectionHold.count }
    ] do
      ConversationActions::Executor.call(execution: action.execution)
    end

    execution = action.execution.reload
    assert_predicate execution, :status_succeeded?
    assert_equal "human_escalation_required", execution.result_code
    assert execution.attention_required?
    assert execution.conversation_escalation
  end

  test "due date, payment status, and invoice resend use refreshed server facts" do
    @invoice.update!(
      due_on: Date.new(2026, 8, 12),
      provider_data: {
        "online_invoice_url" => "https://in.xero.com/INV-001"
      }
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)

    {
      answer_due_date: "August 12, 2026",
      answer_payment_status: "remains outstanding",
      resend_invoice: "https://in.xero.com/INV-001"
    }.each do |action_type, expected|
      action = approve_action(action_type:, arguments: {})
      ConversationActions::Executor.call(execution: action.execution)

      message = action.execution.reload.conversation_message
      assert_predicate action.execution, :status_awaiting_delivery?
      assert_includes message.body, expected
      message.update!(
        status: :sent,
        sent_at: Time.current,
        provider_message_id: "sent-#{action_type}",
        provider_thread_id: @source.provider_thread_id
      )
      ConversationMessages::ActionReplyOutcome.finalize!(message)
    end
  end

  test "missing facts and unsafe invoice URLs fail without sending" do
    @invoice.update!(due_on: nil, provider_data: {})
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)

    %i[answer_due_date resend_invoice].each do |action_type|
      action = approve_action(action_type:, arguments: {})
      assert_no_difference -> { ConversationMessage.direction_outbound.count } do
        ConversationActions::Executor.call(execution: action.execution)
      end
      assert_predicate action.execution.reload, :status_failed?
      assert_equal "fact_unavailable", action.execution.failure_category
    end
  end

  test "future recipient addition requires a current admin and persists once" do
    admin = @account.users.create!(
      name: "Action admin",
      role: :admin,
      active: true
    )
    action = approve_action(
      action_type: :add_recipient,
      arguments: {
        "email" => " Accounts@Example.com ",
        "mode" => "future_reminders"
      },
      actor: admin
    )

    assert_difference -> { CustomerEmailAddress.count }, 1 do
      ConversationActions::Executor.call(execution: action.execution)
    end

    execution = action.execution.reload
    assert_equal "accounts@example.com",
      execution.customer_email_address.email
    assert_equal [ @invoice.customer.email ],
      execution.conversation_message.to_addresses

    assert_no_difference [
      -> { CustomerEmailAddress.count },
      -> { ConversationActionExecution.count }
    ] do
      assert_raises ConversationActions::Commands::Unauthorized do
        approve_action(
          action_type: :add_recipient,
          arguments: {
            "email" => "member-denied@example.com",
            "mode" => "future_reminders"
          }
        )
      end
    end
  end

  test "one-time CC never persists a customer recipient or BCC" do
    action = approve_action(
      action_type: :add_recipient,
      arguments: {
        "email" => "copy@example.com",
        "mode" => "cc_current_reply"
      }
    )

    assert_no_difference -> { CustomerEmailAddress.count } do
      ConversationActions::Executor.call(execution: action.execution)
    end

    message = action.execution.reload.conversation_message
    assert_equal [ @invoice.customer.email ], message.to_addresses
    assert_equal [ "copy@example.com" ], message.cc_addresses
    assert_empty message.bcc_addresses
  end

  test "dispute hold and escalation commit before acknowledgement delivery" do
    action = approve_action(
      action_type: :open_dispute,
      arguments: {}
    )

    assert_difference [
      -> { CollectionHold.status_active.count },
      -> { ConversationEscalation.status_open.count },
      -> { ConversationMessage.kind_dispute_acknowledgement.count }
    ], 1 do
      ConversationActions::Executor.call(execution: action.execution)
    end

    execution = action.execution.reload
    assert_predicate execution.collection_hold, :status_active?
    assert_predicate execution.conversation_escalation, :status_open?
    assert execution.effect_applied_at <=
      execution.conversation_message.created_at
    assert execution.attention_required?
  end

  test "uncertain delivery is not retried and Gmail confirmation reconciles execution" do
    action = approve_action(
      action_type: :answer_payment_status,
      arguments: {}
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: action.execution)
    execution = action.execution.reload
    message = execution.conversation_message

    message.update!(
      status: :failed,
      failure_reason:
        ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON,
      delivery_uncertain: true,
      provider_delivery_started_at: Time.current
    )
    ConversationMessages::ActionReplyOutcome.finalize!(message)

    assert_predicate execution.reload, :status_uncertain?
    assert execution.attention_required?
    assert_includes @invoice.conversation_messages.successful_outbound,
      message
    assert_predicate @conversation.conversation_events
      .kind_conversation_action_execution_unconfirmed
      .sole,
      :persisted?

    message.update!(
      status: :sent,
      sent_at: Time.current,
      provider_message_id: "gmail-reconciled-action",
      provider_thread_id: @source.provider_thread_id,
      failure_reason: nil,
      delivery_uncertain: false
    )
    ConversationMessages::ActionReplyOutcome.finalize!(message)

    assert_predicate execution.reload, :status_succeeded?
    assert_equal "gmail_sent_reconciled", execution.result_code
    assert_predicate @conversation.conversation_events
      .kind_conversation_action_execution_unconfirmed
      .sole,
      :persisted?
    assert_predicate @conversation.conversation_events
      .kind_conversation_action_execution_reconciled
      .sole,
      :persisted?
  end

  test "threaded reply job confirms Gmail delivery and completes execution" do
    action = approve_action(
      action_type: :answer_payment_status,
      arguments: {}
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationMessages::ProviderDelivery.expects(:call).returns(
      ConversationMessages::ProviderDelivery::Result.new(
        provider_message_id: "confirmed-action-reply",
        provider_thread_id: @source.provider_thread_id,
        failure_reason: nil,
        delivery_uncertain: false
      )
    )

    perform_enqueued_jobs(
      only: ConversationMessages::ThreadedReplyJob
    ) do
      ConversationActions::Executor.call(execution: action.execution)
    end

    execution = action.execution.reload
    assert_predicate execution, :status_succeeded?
    assert_equal "reply_delivered", execution.result_code
    assert_predicate execution.conversation_message, :status_sent?
    assert_equal "confirmed-action-reply",
      execution.conversation_message.provider_message_id
  end

  test "invoice deletion removes execution and threaded reply graph in dependency order" do
    action = approve_action(
      action_type: :answer_due_date,
      arguments: {}
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: action.execution)
    execution_id = action.execution.id
    action_id = action.id
    message_ids = @conversation.conversation_messages.pluck(:id)

    assert_nothing_raised { @invoice.destroy! }

    assert_not ConversationActionExecution.exists?(execution_id)
    assert_not ConversationAction.exists?(action_id)
    assert_empty ConversationMessage.where(id: message_ids)
  end

  private
    def approve_action(
      action_type:,
      arguments:,
      proposed_reply: {},
      source_message: @source,
      actor: @actor
    )
      key = "executor-#{action_type}-#{SecureRandom.hex(4)}"
      action = ConversationActions::Proposal.record!(
        conversation: @conversation,
        source_message:,
        action_type:,
        origin_kind: :user,
        created_by_user: actor,
        user_facing_summary: "Execute #{action_type}.",
        arguments:,
        proposed_reply:,
        idempotency_key: key
      )
      approval_key = "#{key}-approval"
      ConversationActions::Approval.call(
        action:,
        revision: action.current_revision,
        actor_user: actor,
        idempotency_key: approval_key,
        snapshot_token: ConversationActions::ActionSnapshot.token_for(
          action:,
          idempotency_key: approval_key
        )
      )
      clear_enqueued_jobs
      action.reload
    end

    def create_source_message(
      provider_message_id: "action-source",
      internet_message_id: "<action-source@example.com>",
      received_at: Time.zone.local(2026, 7, 24, 9)
    )
      @conversation.conversation_messages.create!(
        account: @account,
        invoice: @invoice,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "action-thread",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at:,
        from_address: @invoice.customer.email,
        subject: "Question about INV-001",
        internet_message_id:,
        matching_status: :matched,
        matching_method: :gmail_thread,
        review_required: false,
        automatic: false
      )
    end
end

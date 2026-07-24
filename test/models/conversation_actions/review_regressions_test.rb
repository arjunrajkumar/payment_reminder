require "test_helper"

class ConversationActions::ReviewRegressionsTest < ActiveJob::TestCase
  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @actor = users(:arjun)
    @connection = email_connections(:paid_jar_gmail)
    @source = create_source_message(
      key: SecureRandom.hex(6),
      received_at: Time.zone.local(2026, 7, 24, 9)
    )
  end

  test "a replaced execution claim cannot mutate effects replies or audit state" do
    action = approve_action(
      action_type: :answer_due_date,
      arguments: {}
    )
    execution = action.execution
    original = execution.claim_phase!(expected_phase: :effect)
    execution.update_columns(claimed_at: 1.hour.ago)
    assert execution.recover_stale_execution_claim!(
      before: 30.minutes.ago
    )
    replacement = execution.claim_phase!(expected_phase: :effect)

    assert_no_changes -> {
      execution.reload.attributes.slice(
        "status",
        "claim_token",
        "claim_generation",
        "effect_completed_at"
      )
    } do
      assert_raises ConversationActionExecution::ClaimLost do
        execution.transition_from_claim!(
          original,
          to_status: :succeeded,
          to_phase: :finalized,
          finished_at: Time.current,
          effect_completed_at: Time.current
        )
      end
    end

    assert replacement
    assert_predicate execution.reload, :status_running?
    assert_equal replacement.token, execution.claim_token
    assert_equal replacement.generation, execution.claim_generation
  end

  test "dispute effect commits before disconnected Gmail blocks reply reservation" do
    action = approve_action(action_type: :open_dispute, arguments: {})
    @connection.update_columns(status: "disconnected")

    assert_difference [
      -> { CollectionHold.status_active.count },
      -> { ConversationEscalation.category_dispute.count }
    ], 1 do
      ConversationActions::Executor.call(execution: action.execution)
    end

    execution = action.execution.reload
    assert_predicate execution.collection_hold, :status_active?
    assert_predicate execution.effect_escalation, :status_open?
    assert_predicate execution.delivery_escalation, :status_open?
    assert_predicate execution, :status_failed?
    assert_equal "delivery_unavailable", execution.failure_category
    assert_nil execution.conversation_message
  end

  test "same promise source permits exact replay but rejects a different date" do
    first = approve_action(
      action_type: :record_payment_promise,
      arguments: { "promised_on" => "2026-08-05" }
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: first.execution)
    deliver!(first.execution.reload.conversation_message, key: "promise-one")

    exact = approve_action(
      action_type: :record_payment_promise,
      arguments: { "promised_on" => "2026-08-05" }
    )
    assert_no_difference -> { PaymentPromise.count } do
      ConversationActions::Executor.call(execution: exact.execution)
    end
    assert_equal first.execution.reload.payment_promise,
      exact.execution.reload.payment_promise
    assert_equal "payment_promise_already_recorded",
      exact.execution.result_code
    deliver!(exact.execution.conversation_message, key: "promise-exact")

    conflict = approve_action(
      action_type: :record_payment_promise,
      arguments: { "promised_on" => "2026-08-06" }
    )
    assert_no_difference -> { PaymentPromise.count } do
      ConversationActions::Executor.call(execution: conflict.execution)
    end
    assert_predicate conflict.execution.reload, :status_failed?
    assert_equal "stale_action", conflict.execution.failure_category
  end

  test "an older source cannot resurrect a promise after the newer promise is terminal" do
    newer_source = create_source_message(
      key: SecureRandom.hex(6),
      received_at: @source.received_at + 1.minute
    )
    newer = approve_action(
      action_type: :record_payment_promise,
      arguments: { "promised_on" => "2026-08-08" },
      source_message: newer_source
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: newer.execution)
    newer.execution.reload.payment_promise.fulfill!
    deliver!(newer.execution.conversation_message, key: "newer-promise")

    older = approve_action(
      action_type: :record_payment_promise,
      arguments: { "promised_on" => "2026-08-07" }
    )
    assert_no_difference -> { PaymentPromise.count } do
      ConversationActions::Executor.call(execution: older.execution)
    end

    assert_predicate older.execution.reload, :status_failed?
    assert_equal "stale_action", older.execution.failure_category
  end

  test "reused recipient evidence is linked without claiming a new mutation" do
    admin = @account.users.create!(
      name: "Recipient admin",
      role: :admin,
      active: true
    )
    existing = @invoice.customer.additional_email_addresses.create!(
      email: "accounts@example.com"
    )
    action = approve_action(
      action_type: :add_recipient,
      arguments: {
        "email" => existing.email,
        "mode" => "future_reminders"
      },
      actor: admin
    )

    assert_no_difference -> { CustomerEmailAddress.count } do
      ConversationActions::Executor.call(execution: action.execution)
    end

    execution = action.execution.reload
    assert_equal existing, execution.customer_email_address
    assert_equal "already_present",
      execution.result_metadata.fetch("outcome")
    assert_nil execution.effect_applied_at
    assert execution.effect_completed_at
  end

  test "repeated dispute reuses one correctly paired hold and escalation" do
    first = approve_action(action_type: :open_dispute, arguments: {})
    ConversationActions::Executor.call(execution: first.execution)
    deliver!(first.execution.reload.conversation_message, key: "dispute-one")

    second = approve_action(action_type: :open_dispute, arguments: {})
    assert_no_difference [
      -> { CollectionHold.count },
      -> { ConversationEscalation.category_dispute.count }
    ] do
      ConversationActions::Executor.call(execution: second.execution)
    end

    first_execution = first.execution.reload
    second_execution = second.execution.reload
    assert_equal first_execution.collection_hold,
      second_execution.collection_hold
    assert_equal first_execution.effect_escalation,
      second_execution.effect_escalation
    assert_equal second_execution.collection_hold,
      second_execution.effect_escalation.collection_hold
    assert_equal "dispute_already_open", second_execution.result_code
    assert_nil second_execution.effect_applied_at
  end

  test "initial scheduling exhausts visibly with one terminal audit event" do
    ConversationActions::ExecutionJob.any_instance.stubs(:enqueue)
      .returns(false)
    action = approve_action(
      action_type: :answer_due_date,
      arguments: {}
    )
    execution = action.execution

    4.times do
      execution.reload.update_columns(next_scheduling_at: 1.minute.ago)
      ConversationActions::ReconcileExecutionsJob.perform_now
    end

    assert_predicate execution.reload, :status_failed?
    assert_equal "execution_scheduling_exhausted",
      execution.failure_category
    assert execution.attention_required?
    assert_predicate execution.delivery_escalation, :status_open?
    assert_equal 1, @conversation.conversation_events
      .kind_conversation_action_execution_failed
      .where(
        execution_event_key:
          "execution:#{execution.id}:terminal:failed:execution_scheduling_exhausted"
      ).count
  end

  test "reply scheduling exhaustion preserves the committed local effect" do
    ConversationMessages::ThreadedReplyJob.any_instance.stubs(:enqueue)
      .returns(false)
    action = approve_action(
      action_type: :record_payment_promise,
      arguments: { "promised_on" => "2026-08-10" }
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: action.execution)
    message = action.execution.reload.conversation_message

    4.times do
      message.update_columns(next_reply_scheduling_at: 1.minute.ago)
      ConversationMessages::ActionReplyRequest.enqueue(message.reload)
    end

    assert_predicate action.execution.reload.payment_promise, :status_active?
    assert_predicate message.reload, :status_failed?
    assert_predicate action.execution.reload, :status_failed?
    assert_equal "delivery_failed", action.execution.failure_category
  end

  test "database SENT state defeats a stale failed message object" do
    action = approve_action(
      action_type: :answer_payment_status,
      arguments: {}
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: action.execution)
    stale = action.execution.reload.conversation_message
    stale.assign_attributes(
      status: :failed,
      failure_reason: "stale local failure",
      delivery_uncertain: false
    )
    ConversationMessage.where(id: stale.id).update_all(
      status: "sent",
      sent_at: Time.current,
      provider_message_id: "authoritative-sent",
      provider_thread_id: @source.provider_thread_id,
      failure_reason: nil,
      delivery_uncertain: false
    )

    assert ConversationMessages::ActionReplyOutcome.finalize!(stale)

    execution = action.execution.reload
    assert_predicate execution, :status_succeeded?
    assert_nil execution.delivery_escalation
    assert_equal "reply_delivered", execution.result_code
  end

  test "Gmail SENT repair resolves only delivery failure escalation" do
    action = approve_action(action_type: :open_dispute, arguments: {})
    ConversationActions::Executor.call(execution: action.execution)
    execution = action.execution.reload
    message = execution.conversation_message
    message.mark_delivery_failed!(
      job_id: message.delivery_job_id,
      failure_reason: "definite failure",
      delivery_uncertain: false
    )
    ConversationMessages::ActionReplyOutcome.finalize!(message)
    execution.reload
    dispute_escalation = execution.effect_escalation
    delivery_escalation = execution.delivery_escalation

    message.update!(
      status: :sent,
      sent_at: Time.current,
      provider_message_id: "repaired-dispute",
      provider_thread_id: @source.provider_thread_id,
      failure_reason: nil,
      delivery_uncertain: false
    )
    ConversationMessages::ActionReplyOutcome.finalize!(message)

    assert_predicate execution.reload, :status_succeeded?
    assert_predicate dispute_escalation.reload, :status_open?
    assert_predicate execution.collection_hold.reload, :status_active?
    assert_predicate delivery_escalation.reload, :status_resolved?
    assert execution.attention_required?
  end

  test "finalization audit failure rolls back and remains SQL discoverable" do
    action = approve_action(
      action_type: :answer_payment_status,
      arguments: {}
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: action.execution)
    execution = action.execution.reload
    message = execution.conversation_message
    message.update!(
      status: :sent,
      sent_at: Time.current,
      provider_message_id: "audit-repair-sent",
      provider_thread_id: @source.provider_thread_id
    )
    ConversationEvent.stubs(:record_execution_once!)
      .raises("injected audit failure")

    assert_raises RuntimeError do
      ConversationMessages::ActionReplyOutcome.finalize!(message)
    end
    assert_predicate execution.reload, :status_awaiting_delivery?
    assert_predicate execution, :finalization_pending?
    assert_includes(
      ConversationMessages::ActionReplyOutcome.needing_finalization,
      message
    )

    ConversationEvent.unstub(:record_execution_once!)
    assert ConversationMessages::ActionReplyOutcome.finalize!(message)
    assert_predicate execution.reload, :status_succeeded?
    assert_predicate execution, :finalization_completed?
  end

  test "resolving the action escalation clears its execution attention" do
    action = approve_action(
      action_type: :other,
      arguments: {},
      source_message: nil
    )
    ConversationActions::Executor.call(execution: action.execution)
    execution = action.execution.reload
    escalation = execution.effect_escalation
    key = "resolve-other-#{SecureRandom.hex(4)}"

    escalation.resolve!(
      actor_user: @actor,
      resolution_note: "Handled manually.",
      idempotency_key: key,
      snapshot_token:
        ConversationEscalations::EscalationSnapshot.token_for(
          escalation:,
          idempotency_key: key
        )
    )

    assert_not execution.reload.attention_required?
    assert_predicate escalation.reload, :status_resolved?
  end

  test "handled acknowledgement owns an exact execution attention version" do
    action = approve_action(
      action_type: :answer_due_date,
      arguments: {}
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: action.execution)
    deliver!(
      action.execution.reload.conversation_message,
      key: "attention-version"
    )
    execution = action.execution.reload
    execution.mark_attention!
    Conversations::Attention.recompute!(conversation: @conversation)
    stale_token = Conversations::WorkUnitSnapshot.token_for(
      conversation: @conversation
    )
    execution.mark_attention!
    Conversations::Attention.recompute!(conversation: @conversation)

    assert_raises Conversations::WorkUnitSnapshot::Stale do
      Conversations::Acknowledgement.call(
        conversation: @conversation,
        actor_user: @actor,
        work_unit_token: stale_token
      )
    end
    assert execution.reload.attention_required?

    Conversations::Acknowledgement.call(
      conversation: @conversation,
      actor_user: @actor,
      work_unit_token: Conversations::WorkUnitSnapshot.token_for(
        conversation: @conversation
      )
    )
    assert_not execution.reload.attention_required?
  end

  test "deleted approver evidence remains valid through SENT reconciliation" do
    approver = @account.users.create!(
      name: "Temporary approver",
      role: :member,
      active: true
    )
    action = approve_action(
      action_type: :answer_due_date,
      arguments: {},
      actor: approver
    )
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: action.execution)
    message = action.execution.reload.conversation_message

    approver.destroy!
    assert_predicate action.reload, :valid?
    assert_predicate message.reload, :valid?
    assert_nil action.decided_by_user
    assert_nil message.actor_user

    deliver!(message, key: "deleted-approver")
    assert_predicate action.execution.reload, :status_succeeded?
    assert_equal "Temporary approver",
      action.decision_actor_snapshot.fetch("name")
    assert_equal "Temporary approver",
      message.reload.actor_snapshot.fetch("name")
  end

  test "rejected action retains immutable decider evidence after deletion" do
    decider = @account.users.create!(
      name: "Temporary rejector",
      role: :member,
      active: true
    )
    action = ConversationActions::Proposal.record!(
      conversation: @conversation,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Reject this.",
      idempotency_key: "reject-snapshot-#{SecureRandom.hex(4)}"
    )
    key = "reject-#{SecureRandom.hex(4)}"
    ConversationActions::Rejection.call(
      action:,
      revision: action.current_revision,
      actor_user: decider,
      rationale: "Handled another way.",
      idempotency_key: key,
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action:,
        idempotency_key: key
      )
    )

    decider.destroy!

    assert_predicate action.reload, :valid?
    assert_nil action.decided_by_user
    assert_equal decider.id,
      action.decision_actor_snapshot.fetch("id")
    assert_equal "Temporary rejector",
      action.decision_actor_snapshot.fetch("name")
  end

  test "approval rejects invalid executable context while rejection remains possible" do
    action = ConversationActions::Proposal.record!(
      conversation: @conversation,
      action_type: :answer_due_date,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "No source anchor.",
      idempotency_key: "invalid-approval-#{SecureRandom.hex(4)}"
    )
    approval_key = "invalid-approval-#{SecureRandom.hex(4)}"

    assert_raises ConversationActions::Catalog::InvalidAction do
      ConversationActions::Approval.call(
        action:,
        revision: action.current_revision,
        actor_user: @actor,
        idempotency_key: approval_key,
        snapshot_token: ConversationActions::ActionSnapshot.token_for(
          action:,
          idempotency_key: approval_key
        )
      )
    end
    assert_predicate action.reload, :status_pending_approval?
    assert_nil action.execution

    rejection_key = "valid-rejection-#{SecureRandom.hex(4)}"
    ConversationActions::Rejection.call(
      action:,
      revision: action.current_revision,
      actor_user: @actor,
      rationale: "The source email is missing.",
      idempotency_key: rejection_key,
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action:,
        idempotency_key: rejection_key
      )
    )
    assert_predicate action.reload, :status_rejected?
  end

  test "append-only revision edits executable arguments and bounded wording" do
    action = ConversationActions::Proposal.record!(
      conversation: @conversation,
      source_message: @source,
      action_type: :record_payment_promise,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Record the proposed payment date.",
      arguments: { "promised_on" => "2026-08-03" },
      proposed_reply: {
        "subject" => "Ignored subject",
        "body" => "Ignored factual prose"
      },
      idempotency_key: "editable-#{SecureRandom.hex(4)}"
    )
    key = "revision-#{SecureRandom.hex(4)}"
    revision = ConversationActions::Revision.record!(
      action:,
      author_kind: :user,
      author_user: @actor,
      user_facing_summary: "Record the corrected date.",
      rationale: "The customer corrected the date.",
      base_revision_id: action.current_revision.id,
      arguments: { "promised_on" => "2026-08-09" },
      greeting: "Hello,",
      closing: "Thank you.",
      idempotency_key: key,
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action:,
        idempotency_key: key
      )
    )

    assert_equal "2026-08-09", revision.arguments.fetch("promised_on")
    assert_equal "Hello,",
      revision.proposed_reply.dig("placeholders", "greeting")
    assert_nil revision.proposed_reply["body"]
    approval_key = "approval-#{SecureRandom.hex(4)}"
    ConversationActions::Approval.call(
      action:,
      revision:,
      actor_user: @actor,
      idempotency_key: approval_key,
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action:,
        idempotency_key: approval_key
      )
    )
    clear_enqueued_jobs
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: action.reload.execution)

    message = action.execution.reload.conversation_message
    assert_includes message.body, "Hello,"
    assert_includes message.body, "August 09, 2026"
    assert_includes message.body, "Thank you."
    assert_not_includes message.body, "Ignored factual prose"
  end

  test "preview and reservation use the same recipient subject and body" do
    action = ConversationActions::Proposal.record!(
      conversation: @conversation,
      source_message: @source,
      action_type: :answer_due_date,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Preview the due date.",
      idempotency_key: "preview-#{SecureRandom.hex(4)}"
    )
    preview = ConversationActions::Preview.for(action)
    key = "preview-approval-#{SecureRandom.hex(4)}"
    ConversationActions::Approval.call(
      action:,
      revision: action.current_revision,
      actor_user: @actor,
      idempotency_key: key,
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action:,
        idempotency_key: key
      )
    )
    clear_enqueued_jobs
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    ConversationActions::Executor.call(execution: action.reload.execution)
    message = action.execution.reload.conversation_message

    assert_equal [ preview.recipient ], message.to_addresses
    assert_equal preview.cc_addresses, message.cc_addresses
    assert_equal preview.subject, message.subject
    assert_equal preview.body, message.body
  end

  test "execution lifecycle and result evidence reject arbitrary updates" do
    action = approve_action(
      action_type: :other,
      arguments: {},
      source_message: nil
    )
    ConversationActions::Executor.call(execution: action.execution)

    assert_raises ActiveRecord::ReadOnlyRecord do
      action.execution.reload.update!(
        result_code: "rewritten",
        attention_required: false
      )
    end
  end

  test "MySQL constraints reject invalid execution lifecycle shapes" do
    action = approve_action(
      action_type: :answer_due_date,
      arguments: {}
    )
    execution = action.execution

    assert_raises ActiveRecord::StatementInvalid do
      ConversationActionExecution.where(id: execution.id)
        .update_all(status: "running")
    end
    assert_predicate execution.reload, :status_pending?

    assert_raises ActiveRecord::StatementInvalid do
      ConversationActionExecution.where(id: execution.id).update_all(
        status: "succeeded",
        phase: "effect"
      )
    end
    assert_predicate execution.reload, :status_pending?
    assert_predicate execution, :phase_effect?
  end

  test "factual rendering normalizes terminal balances and uses safe fallback URL" do
    @invoice.update!(
      status: :paid,
      amount_due: 125,
      paid_on: Date.new(2026, 7, 20)
    )
    definition = ConversationActions::Catalog.validate!(
      action_type: :answer_outstanding_amount,
      arguments: {},
      proposed_reply: {}
    )
    rendered = ConversationActions::ReplyRenderer.render!(
      definition:,
      invoice: @invoice,
      account: @account,
      at: Time.zone.local(2026, 7, 24, 23, 30)
    )
    assert_includes rendered.body, "paid"
    assert_includes rendered.body, "no outstanding balance"
    assert_not_includes rendered.body, "USD 125.00"

    @invoice.update!(
      status: :open,
      provider_data: {
        "online_invoice_url" => "https://in.xero.com@evil.example/invoice",
        "invoice_pdf_url" => "https://in.xero.com/safe-invoice"
      }
    )
    resend = ConversationActions::Catalog.validate!(
      action_type: :resend_invoice,
      arguments: {},
      proposed_reply: {}
    )
    fallback = ConversationActions::ReplyRenderer.render!(
      definition: resend,
      invoice: @invoice,
      account: @account
    )
    assert_includes fallback.body, "https://in.xero.com/safe-invoice"
    assert_not_includes fallback.body, "evil.example"
  end

  private
    def approve_action(
      action_type:,
      arguments:,
      source_message: @source,
      actor: @actor
    )
      key = "review-#{action_type}-#{SecureRandom.hex(5)}"
      action = ConversationActions::Proposal.record!(
        conversation: @conversation,
        source_message:,
        action_type:,
        origin_kind: :user,
        created_by_user: @actor,
        user_facing_summary: "Execute #{action_type}.",
        arguments:,
        proposed_reply: {},
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

    def create_source_message(key:, received_at:)
      @conversation.conversation_messages.create!(
        account: @account,
        invoice: @invoice,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id: "review-source-#{key}",
        provider_thread_id: "review-thread",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at:,
        from_address: @invoice.customer.email,
        subject: "Question about INV-001",
        internet_message_id: "<review-source-#{key}@example.com>",
        matching_status: :matched,
        matching_method: :gmail_thread,
        review_required: false,
        automatic: false
      )
    end

    def deliver!(message, key:)
      message.update!(
        status: :sent,
        sent_at: Time.current,
        provider_message_id: "sent-#{key}",
        provider_thread_id: message.requested_provider_thread_id,
        failure_reason: nil,
        delivery_uncertain: false
      )
      ConversationMessages::ActionReplyOutcome.finalize!(message)
    end
end

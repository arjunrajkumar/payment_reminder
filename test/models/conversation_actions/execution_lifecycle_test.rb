require "test_helper"

class ConversationActions::ExecutionLifecycleTest < ActiveJob::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @actor = users(:arjun)
    connection = email_connections(:paid_jar_gmail)
    @source = @conversation.conversation_messages.create!(
      account: @invoice.account,
      invoice: @invoice,
      email_connection: connection,
      email_connection_generation: connection.credential_generation,
      provider_account_id: connection.provider_account_id,
      provider_message_id: "execution-lifecycle-source",
      provider_thread_id: "execution-lifecycle-thread",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      from_address: @invoice.customer.email,
      internet_message_id: "<execution-lifecycle@example.com>",
      matching_status: :matched,
      matching_method: :gmail_thread
    )
    @action = ConversationActions::Proposal.record!(
      conversation: @conversation,
      source_message: @source,
      action_type: :answer_outstanding_amount,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Answer the outstanding amount.",
      arguments: {},
      proposed_reply: {
        "subject" => "Untrusted subject",
        "body" => "The amount due is USD 999,999.99."
      },
      idempotency_key: "amount-execution"
    )
  end

  test "approval atomically creates one execution for the exact decided revision" do
    revision = @action.current_revision
    token = approval_token("approve-amount")

    assert_difference [
      -> { ConversationActionExecution.count },
      -> { ConversationEvent.kind_conversation_action_execution_queued.count }
    ], 1 do
      assert_enqueued_jobs 1, only: ConversationActions::ExecutionJob do
        ConversationActions::Approval.call(
          action: @action,
          revision:,
          actor_user: @actor,
          idempotency_key: "approve-amount",
          snapshot_token: token
        )
      end
    end

    execution = @action.reload.execution
    assert_equal revision, execution.conversation_action_revision
    assert_equal @actor.id, execution.approver_snapshot.fetch("id")

    assert_no_difference [
      -> { ConversationActionExecution.count },
      -> { ConversationEvent.kind_conversation_action_execution_queued.count }
    ] do
      assert_enqueued_jobs 0, only: ConversationActions::ExecutionJob do
        ConversationActions::Approval.call(
          action: @action,
          revision:,
          actor_user: @actor,
          idempotency_key: "approve-amount",
          snapshot_token: token
        )
      end
    end
  end

  test "a rejected action has no execution" do
    revision = @action.current_revision

    ConversationActions::Rejection.call(
      action: @action,
      revision:,
      actor_user: @actor,
      rationale: "Do not answer.",
      idempotency_key: "reject-amount",
      snapshot_token: approval_token("reject-amount")
    )

    assert_nil @action.reload.execution
  end

  test "server rendering ignores malicious proposed factual prose" do
    @invoice.update!(amount_due: BigDecimal("1234.50"), currency: "USD")
    rendered = ConversationActions::ReplyRenderer.render!(
      definition: ConversationActions::Catalog.validate!(
        action_type: @action.action_type,
        arguments: {},
        proposed_reply: @action.current_revision.proposed_reply
      ),
      invoice: @invoice,
      account: @invoice.account
    )

    assert_includes rendered.body, "USD 1,234.50"
    assert_not_includes rendered.body, "999,999.99"
    assert_not_equal "Untrusted subject", rendered.subject
  end

  test "enqueue false return leaves recoverable durable pending work" do
    ConversationActions::ExecutionJob.any_instance
      .stubs(:enqueue)
      .returns(false)

    ConversationActions::Approval.call(
      action: @action,
      revision: @action.current_revision,
      actor_user: @actor,
      idempotency_key: "approve-enqueue-false",
      snapshot_token: approval_token("approve-enqueue-false")
    )

    execution = @action.reload.execution
    assert_predicate execution, :status_pending?
    assert_equal 1, execution.scheduling_attempts
    assert_predicate execution, :scheduling_reserved?
    assert execution.last_scheduling_error.present?
  end

  test "reconciler enqueues orphaned pending work and recovers only safe stale claims" do
    ConversationActions::Approval.call(
      action: @action,
      revision: @action.current_revision,
      actor_user: @actor,
      idempotency_key: "approve-reconcile",
      snapshot_token: approval_token("approve-reconcile")
    )
    execution = @action.reload.execution
    clear_enqueued_jobs
    execution.update_columns(
      status: "running",
      claim_token: "abandoned",
      claimed_at: 1.hour.ago,
      attempts: 1
    )

    assert_enqueued_with(job: ConversationActions::ExecutionJob) do
      ConversationActions::ReconcileExecutionsJob.perform_now
    end

    assert_predicate execution.reload, :status_pending?
    assert_nil execution.claim_token
  end

  test "stale claim after a durable effect resumes without reapplying it" do
    ConversationActions::Approval.call(
      action: @action,
      revision: @action.current_revision,
      actor_user: @actor,
      idempotency_key: "approve-uncertain-claim",
      snapshot_token: approval_token("approve-uncertain-claim")
    )
    execution = @action.reload.execution
    clear_enqueued_jobs
    effect_at = 1.hour.ago
    execution.update_columns(
      status: "running",
      claim_token: "abandoned-after-effect",
      claimed_at: 1.hour.ago,
      attempts: 1,
      effect_applied_at: effect_at
    )

    assert_enqueued_jobs 1, only: ConversationActions::ExecutionJob do
      ConversationActions::ReconcileExecutionsJob.perform_now
    end

    assert_predicate execution.reload, :status_pending?
    assert_equal effect_at.to_i, execution.effect_applied_at.to_i
  end

  test "execution evidence rejects independent deletion" do
    ConversationActions::Approval.call(
      action: @action,
      revision: @action.current_revision,
      actor_user: @actor,
      idempotency_key: "approve-retained",
      snapshot_token: approval_token("approve-retained")
    )

    assert_raises ActiveRecord::DeleteRestrictionError do
      @action.execution.destroy!
    end
    assert_raises ActiveRecord::ReadOnlyRecord do
      @action.execution.delete
    end
  end

  test "approver removal nullifies live links and retains the immutable snapshot" do
    approver = @action.account.users.create!(
      name: "Temporary approver",
      role: :member,
      active: true
    )
    key = "approve-before-user-removal"
    ConversationActions::Approval.call(
      action: @action,
      revision: @action.current_revision,
      actor_user: approver,
      idempotency_key: key,
      snapshot_token: approval_token(key)
    )
    execution = @action.reload.execution

    assert_nothing_raised { approver.destroy! }

    assert_nil @action.reload.decided_by_user
    assert_nil execution.reload.approved_by_user
    assert_equal "Temporary approver",
      execution.approver_snapshot.fetch("name")
  end

  private
    def approval_token(idempotency_key)
      ConversationActions::ActionSnapshot.token_for(
        action: @action.reload,
        idempotency_key:
      )
    end
end

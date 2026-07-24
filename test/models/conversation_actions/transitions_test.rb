require "test_helper"

class ConversationActions::TransitionsTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @actor = users(:arjun)
    @action = create_action
  end

  test "editing appends a revision and retains structured arguments" do
    original = @action.current_revision
    token = action_token("revision-two")

    revised = ConversationActions::Revision.record!(
      action: @action,
      author_kind: :user,
      author_user: @actor,
      user_facing_summary: "Use the corrected human summary.",
      rationale: "Corrected after review.",
      proposed_reply: {
        "subject" => "Corrected subject",
        "body" => "Corrected reply body."
      },
      idempotency_key: "revision-two",
      snapshot_token: token
    )

    assert_equal 2, revised.revision_number
    assert_equal original.arguments, revised.arguments
    assert_equal original.invoice_id, revised.invoice_id
    assert_equal original.customer_id, revised.customer_id
    assert_equal "Initial summary", original.reload.user_facing_summary
    assert_equal revised, @action.reload.current_revision
    assert_equal 1, @conversation.conversation_events
      .kind_conversation_action_revised.count
  end

  test "approval binds to the exact revision and exact retry is idempotent" do
    revision = @action.current_revision
    token = action_token("approve-one")

    assert_difference -> {
      @conversation.conversation_events.kind_conversation_action_approved.count
    }, 1 do
      ConversationActions::Approval.call(
        action: @action,
        revision:,
        actor_user: @actor,
        note: "Reviewed.",
        idempotency_key: "approve-one",
        snapshot_token: token
      )
    end

    assert_no_difference -> {
      @conversation.conversation_events.kind_conversation_action_approved.count
    } do
      ConversationActions::Approval.call(
        action: @action,
        revision:,
        actor_user: @actor,
        note: "Reviewed.",
        idempotency_key: "approve-one",
        snapshot_token: token
      )
    end

    @action.reload
    assert_predicate @action, :status_approved?
    assert_equal revision, @action.decided_revision
    assert_equal @actor, @action.decided_by_user
    assert_equal "Reviewed.", @action.decision_note
  end

  test "editing makes an older approval snapshot stale without a partial decision" do
    old_revision = @action.current_revision
    stale_token = action_token("approve-stale")
    ConversationActions::Revision.record!(
      action: @action,
      author_kind: :user,
      author_user: @actor,
      user_facing_summary: "New current summary",
      rationale: nil,
      proposed_reply: {},
      idempotency_key: "revision-before-approval",
      snapshot_token: action_token("revision-before-approval")
    )

    assert_no_difference -> {
      @conversation.conversation_events.kind_conversation_action_approved.count
    } do
      assert_raises ConversationActions::StaleControl do
        ConversationActions::Approval.call(
          action: @action,
          revision: old_revision,
          actor_user: @actor,
          note: nil,
          idempotency_key: "approve-stale",
          snapshot_token: stale_token
        )
      end
    end

    assert_predicate @action.reload, :status_pending_approval?
    assert_nil @action.decided_revision
  end

  test "rejection requires and retains a concise human rationale" do
    assert_raises ActiveRecord::RecordInvalid do
      ConversationActions::Rejection.call(
        action: @action,
        revision: @action.current_revision,
        actor_user: @actor,
        rationale: " ",
        idempotency_key: "reject-blank",
        snapshot_token: action_token("reject-blank")
      )
    end

    ConversationActions::Rejection.call(
      action: @action,
      revision: @action.current_revision,
      actor_user: @actor,
      rationale: "The proposal uses the wrong customer date.",
      idempotency_key: "reject-one",
      snapshot_token: action_token("reject-one")
    )

    assert_predicate @action.reload, :status_rejected?
    assert_equal "The proposal uses the wrong customer date.", @action.decision_note
  end

  test "approval records state only and causes no command side effects" do
    counts = -> {
      [
        ConversationMessage.count,
        PaymentPromise.count,
        CollectionHold.count,
        ConversationEscalation.count
      ]
    }

    assert_no_changes counts do
      ConversationActions::Approval.call(
        action: @action,
        revision: @action.current_revision,
        actor_user: @actor,
        note: nil,
        idempotency_key: "approve-no-execution",
        snapshot_token: action_token("approve-no-execution")
      )
    end
  end

  test "mark handled cannot hide a pending approval and approval clears its attention" do
    Conversations::Acknowledgement.call(
      conversation: @conversation,
      actor_user: @actor,
      work_unit_token: Conversations::WorkUnitSnapshot.token_for(
        conversation: @conversation
      )
    )

    assert_equal @action.current_revision.created_at,
      @conversation.reload.attention_required_at

    ConversationActions::Approval.call(
      action: @action,
      revision: @action.current_revision,
      actor_user: @actor,
      idempotency_key: "approve-attention",
      snapshot_token: action_token("approve-attention")
    )

    assert_nil @conversation.reload.attention_required_at
  end

  test "direct updates cannot rewrite approved action provenance or lifecycle" do
    other_actor = @action.account.users.create!(
      name: "Other workflow actor",
      role: :member
    )
    ConversationActions::Approval.call(
      action: @action,
      revision: @action.current_revision,
      actor_user: @actor,
      idempotency_key: "approve-before-direct-update",
      snapshot_token: action_token("approve-before-direct-update")
    )

    %i[action_type origin_kind created_by_user status decided_by_user].each do |field|
      value = {
        action_type: :other,
        origin_kind: :ai,
        created_by_user: nil,
        status: :pending_approval,
        decided_by_user: other_actor
      }.fetch(field)
      assert_raises ActiveRecord::ReadOnlyRecord do
        @action.reload.update!(field => value)
      end
    end
  end

  test "validation bypass and public internal APIs cannot bypass action audit" do
    @action.status = :approved
    @action.decided_revision = @action.current_revision
    @action.decided_by_user = @actor
    @action.decided_at = Time.current
    @action.decision_idempotency_key = "validation-bypass"
    assert_raises ActiveRecord::ReadOnlyRecord do
      @action.save!(validate: false)
    end
    assert_raises NoMethodError do
      @action.record_decision!(status: :approved)
    end
    other_invoice = @invoice.dup
    other_invoice.external_id = "private-transfer-action"
    other_invoice.number = "INV-PRIVATE-ACTION"
    other_invoice.save!
    assert_raises NoMethodError do
      @action.transfer_to_conversation!(
        Conversation.for_invoice!(invoice: other_invoice)
      )
    end
    assert_raises NoMethodError do
      @action.destroy_for_parent!
    end
    assert_predicate @action.reload, :status_pending_approval?
    assert_empty @conversation.conversation_events
      .kind_conversation_action_approved
  end

  private
    def create_action
      ConversationActions::Proposal.record!(
        conversation: @conversation,
        action_type: :answer_due_date,
        origin_kind: :user,
        created_by_user: @actor,
        user_facing_summary: "Initial summary",
        rationale: nil,
        arguments: { "source" => "invoice" },
        proposed_reply: {
          "subject" => "Invoice due date",
          "body" => "The invoice is due soon."
        },
        idempotency_key: "transition-action"
      )
    end

    def action_token(idempotency_key)
      ConversationActions::ActionSnapshot.token_for(
        action: @action.reload,
        idempotency_key:
      )
    end
end

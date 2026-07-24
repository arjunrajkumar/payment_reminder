require "test_helper"

class WorkflowRelatedRecordReconciliationTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @actor = users(:arjun)
    @connection = email_connections(:paid_jar_gmail)
    @source = @account.conversations.create!
    @source_message = review_message(
      conversation: @source,
      provider_message_id: "related-source"
    )
    @action = ConversationActions::Proposal.record!(
      conversation: @source,
      source_message: @source_message,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Review the related workflow.",
      idempotency_key: "related-workflow-action"
    )
    @owner = Conversation.for_invoice!(invoice: @invoice)
    review_message(
      conversation: @owner,
      invoice: @invoice,
      provider_message_id: "related-owner"
    )
  end

  test "constructing placement is side-effect free and the original action is reloaded" do
    service = hold_service(idempotency_key: "related-hold")

    assert_equal @source, @action.reload.conversation
    assert_empty @owner.collection_holds
    assert_empty @owner.conversation_events.kind_collection_hold_placed

    hold = service.call

    assert_equal @owner, hold.conversation
    assert_equal @owner, hold.conversation_action.conversation
    assert_equal @action, hold.conversation_action
    assert_equal hold, hold_service(idempotency_key: "related-hold").call
    assert_equal 1, @owner.collection_holds
      .where(idempotency_key: "related-hold").count
    assert_equal 1, @owner.conversation_events
      .kind_collection_hold_placed.count
  end

  test "opening reloads the original pre-transfer action and replays exactly" do
    escalation = opening_service(
      idempotency_key: "related-escalation"
    ).call

    assert_equal @owner, escalation.conversation
    assert_equal @owner, escalation.conversation_action.conversation
    assert_equal @action, escalation.conversation_action
    assert_equal escalation, opening_service(
      idempotency_key: "related-escalation"
    ).call
    assert_equal 1, @owner.conversation_escalations
      .where(idempotency_key: "related-escalation").count
    assert_equal 1, @owner.conversation_events
      .kind_conversation_escalated.count
  end

  test "invalid hold creation rolls back owner transfer events and attention" do
    invalid_actor = Account.create!(name: "Invalid hold actor").users.create!(
      name: "Invalid hold actor"
    )
    initial_source_attention = @source.reload.attention_required_at
    initial_owner_attention = @owner.reload.attention_required_at

    assert_raises ActiveRecord::RecordNotFound do
      hold_service(
        idempotency_key: "invalid-related-hold",
        actor: invalid_actor
      ).call
    end

    assert_equal @source, @action.reload.conversation
    if initial_source_attention
      assert_equal initial_source_attention, @source.reload.attention_required_at
    else
      assert_nil @source.reload.attention_required_at
    end
    if initial_owner_attention
      assert_equal initial_owner_attention, @owner.reload.attention_required_at
    else
      assert_nil @owner.reload.attention_required_at
    end
    assert_empty @account.collection_holds
      .where(idempotency_key: "invalid-related-hold")
    assert_empty @owner.conversation_events.kind_collection_hold_placed
  ensure
    invalid_actor&.account&.destroy!
  end

  test "invalid escalation creation rolls back owner transfer and audit" do
    invalid_actor = Account.create!(
      name: "Invalid escalation actor"
    ).users.create!(name: "Invalid escalation actor")

    assert_raises ActiveRecord::RecordNotFound do
      opening_service(
        idempotency_key: "invalid-related-escalation",
        actor: invalid_actor
      ).call
    end

    assert_equal @source, @action.reload.conversation
    assert_empty @account.conversation_escalations
      .where(idempotency_key: "invalid-related-escalation")
    assert_empty @owner.conversation_events.kind_conversation_escalated
  ensure
    invalid_actor&.account&.destroy!
  end

  private
    def hold_service(idempotency_key:, actor: @actor)
      CollectionHolds::Placement.new(
        conversation: @source,
        conversation_action: @action,
        reason: :manual,
        placed_by_kind: :user,
        placed_by_user: actor,
        idempotency_key:
      )
    end

    def opening_service(idempotency_key:, actor: @actor)
      ConversationEscalations::Opening.new(
        conversation: @source,
        conversation_action: @action,
        category: :ambiguous,
        priority: :high,
        summary: "Review the reconciled action.",
        opened_by_kind: :user,
        opened_by_user: actor,
        idempotency_key:
      )
    end

    def review_message(conversation:, provider_message_id:, invoice: nil)
      conversation.conversation_messages.create!(
        account: @account,
        invoice:,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "related-workflow-thread",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.current,
        matching_status: invoice ? :matched : :unmatched,
        matching_method: invoice ? :gmail_thread : :none,
        review_required: true
      )
    end
end

require "test_helper"

class Conversations::ReviewWorkUnitAcceptanceTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @actor = users(:arjun)
    @connection = email_connections(:paid_jar_gmail)
    @owner = Conversation.for_invoice!(invoice: @invoice)
  end

  test "public and locked membership include every same-thread sibling message" do
    sibling = @account.conversations.create!
    owner_anchor = review_message(
      conversation: @owner,
      invoice: @invoice,
      provider_message_id: "membership-owner"
    )
    sibling_anchor = review_message(
      conversation: sibling,
      provider_message_id: "membership-anchor"
    )
    inbound = clean_message(
      conversation: sibling,
      provider_message_id: "membership-inbound",
      direction: :inbound
    )
    outbound = clean_message(
      conversation: sibling,
      provider_message_id: "membership-outbound",
      direction: :outbound
    )

    public_messages = Conversations::ReviewWorkUnit
      .message_scope_for_conversation(conversation: @owner)
      .order(:id)
      .to_a
    snapshot = nil
    Conversations::ReviewWorkUnit.with_reconciled_workflow_owner(
      conversation: @owner
    ) do |_owner, current|
      snapshot = current
    end

    assert_equal(
      [ owner_anchor, sibling_anchor, inbound, outbound ].sort_by(&:id),
      public_messages
    )
    assert_equal public_messages.map(&:id), snapshot.message_ids
    assert Conversations::ReviewWorkUnit.includes_message?(
      conversation: @owner,
      message: inbound
    )
    assert_equal public_messages,
      Conversations::Detail.call(conversation: @owner).timeline.messages
    assert_equal outbound,
      Conversations::Inbox.decorate(
        account: @account,
        conversations: [ @owner ]
      ).sole.latest_message

    action = ConversationActions::Proposal.record!(
      conversation: @owner,
      source_message: inbound,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Use every visible work-unit message.",
      idempotency_key: "membership-action"
    )
    escalation = ConversationEscalations::Opening.call(
      conversation: @owner,
      source_message: outbound,
      category: :ambiguous,
      priority: :high,
      summary: "Escalate visible outbound evidence.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "membership-escalation"
    )
    hold = CollectionHolds::Placement.call(
      conversation: @owner,
      source_message: outbound,
      conversation_action: action,
      reason: :manual,
      placed_by_kind: :user,
      placed_by_user: @actor,
      idempotency_key: "membership-hold"
    )

    assert_equal @owner, action.conversation
    assert_equal @owner, escalation.conversation
    assert_equal @owner, hold.conversation
    assert @owner.reload.attention_required_at
    assert_includes Conversations::Inbox.call(account: @account), @owner
  end

  test "a split invoice work unit is rejected before any workflow write" do
    other_invoice = @invoice.invoice_source.invoices.create!(
      account: @account,
      customer: @invoice.customer,
      external_id: SecureRandom.uuid,
      status: :open,
      amount_due: 50
    )
    other_owner = Conversation.for_invoice!(invoice: other_invoice)
    review_message(
      conversation: @owner,
      invoice: @invoice,
      provider_message_id: "split-first"
    )
    review_message(
      conversation: other_owner,
      invoice: other_invoice,
      provider_message_id: "split-second"
    )

    assert_no_difference(
      -> { @account.conversation_actions.count },
      -> { @account.conversation_events.count }
    ) do
      assert_raises Conversations::ReviewWorkUnit::SplitInvoiceWorkUnit do
        ConversationActions::Proposal.record!(
          conversation: @owner,
          action_type: :other,
          origin_kind: :user,
          created_by_user: @actor,
          user_facing_summary: "Must not cross invoice ownership.",
          idempotency_key: "split-membership-action"
        )
      end
    end
  end

  test "workflow-only audit events remain visible once and account scoped" do
    customer_conversation = @account.conversations.create!(
      customer: @invoice.customer
    )
    action = ConversationActions::Proposal.record!(
      conversation: customer_conversation,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Source-less action.",
      idempotency_key: "timeline-source-less-action"
    )
    escalation = ConversationEscalations::Opening.call(
      conversation: customer_conversation,
      category: :ambiguous,
      priority: :high,
      summary: "Source-less escalation.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "timeline-source-less-escalation"
    )
    hold = CollectionHolds::Placement.call(
      conversation: @owner,
      reason: :manual,
      placed_by_kind: :user,
      placed_by_user: @actor,
      idempotency_key: "timeline-source-less-hold"
    )
    other_account = Account.create!(name: "Timeline isolation")
    other_conversation = other_account.conversations.create!
    ConversationEvent.record!(
      conversation: other_conversation,
      kind: :conversation_action_created,
      actor_kind: :system,
      metadata: { "conversation_action_id" => action.id }
    )

    customer_events = Conversations::Detail.call(
      conversation: customer_conversation
    ).timeline.events
    invoice_events = Conversations::Detail.call(
      conversation: @owner
    ).timeline.events

    assert_equal 1, customer_events.count { |event|
      event.metadata["conversation_action_id"] == action.id
    }
    assert_equal 1, customer_events.count { |event|
      event.metadata["conversation_escalation_id"] == escalation.id
    }
    assert_equal 1, invoice_events.count { |event|
      event.metadata["collection_hold_id"] == hold.id
    }
    assert customer_events.all? { _1.account_id == @account.id }
    assert_includes Conversations::Inbox.call(account: @account),
      customer_conversation
    assert customer_conversation.reload.attention_required_at
  ensure
    other_account&.destroy!
  end

  private
    def review_message(conversation:, provider_message_id:, invoice: nil)
      conversation.conversation_messages.create!(
        account: @account,
        invoice:,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "acceptance-work-unit-thread",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: 2.minutes.ago,
        matching_status: invoice ? :matched : :unmatched,
        matching_method: invoice ? :gmail_thread : :none,
        review_required: true
      )
    end

    def clean_message(conversation:, provider_message_id:, direction:)
      inbound = direction == :inbound
      conversation.conversation_messages.create!(
        account: @account,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "acceptance-work-unit-thread",
        direction:,
        kind: inbound ? :customer_email : :manual_email,
        status: inbound ? :received : :sent,
        received_at: inbound ? 1.minute.ago : nil,
        sent_at: inbound ? nil : Time.current,
        matching_status: :matched,
        matching_method: :gmail_thread,
        review_required: false
      )
    end
end

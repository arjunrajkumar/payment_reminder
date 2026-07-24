require "test_helper"

class ActionHoldEscalationDeletionTest < ActiveSupport::TestCase
  test "invoice destruction removes the complete workflow in dependency order" do
    invoice = invoices(:xero_invoice)
    conversation = Conversation.for_invoice!(invoice:)
    actor = users(:arjun)
    action = ConversationActions::Proposal.record!(
      conversation:,
      action_type: :open_dispute,
      origin_kind: :user,
      created_by_user: actor,
      user_facing_summary: "Open a reviewed dispute.",
      idempotency_key: "deletion-action"
    )
    hold = CollectionHolds::Placement.call(
      conversation:,
      conversation_action: action,
      reason: :dispute,
      placed_by_kind: :user,
      placed_by_user: actor,
      idempotency_key: "deletion-hold"
    )
    escalation = ConversationEscalations::Opening.call(
      conversation:,
      conversation_action: action,
      collection_hold: hold,
      category: :dispute,
      priority: :high,
      summary: "Deletion-order dispute.",
      opened_by_kind: :user,
      opened_by_user: actor,
      idempotency_key: "deletion-escalation"
    )
    ids = {
      conversation: conversation.id,
      action: action.id,
      revision: action.current_revision.id,
      hold: hold.id,
      escalation: escalation.id
    }

    assert_nothing_raised { invoice.destroy! }

    assert_not Conversation.exists?(ids.fetch(:conversation))
    assert_not ConversationAction.exists?(ids.fetch(:action))
    assert_not ConversationActionRevision.exists?(ids.fetch(:revision))
    assert_not CollectionHold.exists?(ids.fetch(:hold))
    assert_not ConversationEscalation.exists?(ids.fetch(:escalation))
    assert_not ConversationEvent.exists?(conversation_id: ids.fetch(:conversation))
  end

  test "customer destruction removes customer-only workflow evidence in dependency order" do
    account, actor, source, customer = create_account_tree("customer")
    conversation = account.conversations.create!(customer:)
    action = create_customer_workflow(
      conversation:,
      actor:,
      suffix: "customer"
    )
    escalation = conversation.conversation_escalations.sole

    assert_nothing_raised { customer.destroy! }

    assert_nil conversation.reload.customer
    assert_nil action.current_revision.reload.customer
    assert_nil escalation.reload.customer
    assert_predicate source.reload, :persisted?
  ensure
    account&.destroy! if account&.persisted?
  end

  test "invoice source destruction removes invoice and customer-only workflows" do
    account, actor, source, customer = create_account_tree("source")
    customer_conversation = account.conversations.create!(customer:)
    create_customer_workflow(
      conversation: customer_conversation,
      actor:,
      suffix: "source-customer"
    )
    invoice = create_invoice(
      account:,
      source:,
      customer:,
      suffix: "source"
    )
    create_invoice_workflow(invoice:, actor:, suffix: "source-invoice")

    assert_nothing_raised { source.destroy! }

    assert_not InvoiceSource.exists?(source.id)
    assert_not Customer.exists?(customer.id)
    assert_equal 1, account.conversation_actions.reload.count
    assert_equal 1, account.conversation_escalations.reload.count
    assert_empty account.collection_holds.reload
  ensure
    account&.destroy! if account&.persisted?
  end

  test "account destruction removes workflows before every referenced actor" do
    account, creator, source, customer = create_account_tree("account")
    decider = account.users.create!(name: "Decider", role: :member)
    releaser = account.users.create!(name: "Releaser", role: :member)
    resolver = account.users.create!(name: "Resolver", role: :member)
    invoice = create_invoice(
      account:,
      source:,
      customer:,
      suffix: "account"
    )
    conversation = Conversation.for_invoice!(invoice:)
    action, hold, escalation = create_invoice_workflow(
      invoice:,
      actor: creator,
      suffix: "account"
    )
    ConversationActions::Approval.call(
      action:,
      revision: action.current_revision,
      actor_user: decider,
      idempotency_key: "account-decision",
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action:,
        idempotency_key: "account-decision"
      )
    )
    hold.release!(
      actor_user: releaser,
      idempotency_key: "account-release",
      snapshot_token: CollectionHolds::HoldSnapshot.token_for(
        hold:,
        idempotency_key: "account-release"
      )
    )
    escalation.resolve!(
      actor_user: resolver,
      resolution_note: "Resolved before account deletion.",
      idempotency_key: "account-resolution",
      snapshot_token: ConversationEscalations::EscalationSnapshot.token_for(
        escalation:,
        idempotency_key: "account-resolution"
      )
    )
    user_ids = [ creator.id, decider.id, releaser.id, resolver.id ]

    assert_nothing_raised { account.destroy! }

    assert_not Account.exists?(account.id)
    assert_empty User.where(id: user_ids)
    assert_not Conversation.exists?(conversation.id)
  end

  test "workflow evidence still rejects independent deletion" do
    invoice = invoices(:xero_invoice)
    action, hold, escalation = create_invoice_workflow(
      invoice:,
      actor: users(:arjun),
      suffix: "independent"
    )

    assert_raises(ActiveRecord::DeleteRestrictionError) { action.destroy! }
    assert_raises(ActiveRecord::DeleteRestrictionError) { hold.destroy! }
    assert_raises(ActiveRecord::DeleteRestrictionError) { escalation.destroy! }
    assert_raises(ActiveRecord::ReadOnlyRecord) { hold.delete }
    assert_raises(ActiveRecord::ReadOnlyRecord) { escalation.delete }
    assert_predicate hold.reload, :persisted?
    assert_predicate escalation.reload, :persisted?
    assert_equal hold.id, conversation_event_metadata_id(
      kind: :collection_hold_placed,
      key: "collection_hold_id"
    )
    assert_equal escalation.id, conversation_event_metadata_id(
      kind: :conversation_escalated,
      key: "conversation_escalation_id"
    )
  end

  test "historical customer references survive deletion after invoice correction" do
    invoice = invoices(:xero_invoice)
    original_customer = invoice.customer
    action, hold, escalation = create_invoice_workflow(
      invoice:,
      actor: users(:arjun),
      suffix: "corrected-customer-deletion"
    )
    replacement = invoice.invoice_source.customers.create!(
      account: invoice.account,
      external_id: "corrected-customer-deletion",
      name: "Corrected customer deletion",
      email: "corrected-deletion@example.com"
    )
    invoice.update!(customer: replacement)

    assert_nothing_raised { original_customer.destroy! }

    assert_nil action.current_revision.reload.customer
    assert_nil hold.reload.customer
    assert_nil escalation.reload.customer
    assert_equal original_customer.id, hold.customer_snapshot.fetch("id")
    assert_predicate hold, :valid?
  end

  test "invoice source deletion handles corrected historical customer snapshots" do
    account, actor, source, original_customer = create_account_tree(
      "corrected-source"
    )
    invoice = create_invoice(
      account:,
      source:,
      customer: original_customer,
      suffix: "corrected-source"
    )
    create_invoice_workflow(
      invoice:,
      actor:,
      suffix: "corrected-source"
    )
    replacement = source.customers.create!(
      account:,
      external_id: "corrected-source-replacement",
      name: "Corrected source replacement",
      email: "corrected-source@example.com"
    )
    invoice.update!(customer: replacement)

    assert_nothing_raised { source.destroy! }
    assert_not InvoiceSource.exists?(source.id)
  ensure
    account&.destroy! if account&.persisted?
  end

  private
    def conversation_event_metadata_id(kind:, key:)
      ConversationEvent.public_send("kind_#{kind}").order(:id).last
        .metadata.fetch(key)
    end

    def create_account_tree(suffix)
      account = Account.create!(name: "Deletion #{suffix}")
      actor = account.users.create!(name: "Creator", role: :owner)
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "deletion-source-#{suffix}"
      )
      customer = source.customers.create!(
        account:,
        external_id: "deletion-customer-#{suffix}",
        name: "Deletion customer",
        email: "deletion-#{suffix}@example.com"
      )
      [ account, actor, source, customer ]
    end

    def create_invoice(account:, source:, customer:, suffix:)
      source.invoices.create!(
        account:,
        customer:,
        external_id: "deletion-invoice-#{suffix}",
        status: :open,
        amount_due: 100
      )
    end

    def create_customer_workflow(conversation:, actor:, suffix:)
      action = ConversationActions::Proposal.record!(
        conversation:,
        action_type: :other,
        origin_kind: :user,
        created_by_user: actor,
        user_facing_summary: "Customer-only deletion workflow.",
        idempotency_key: "customer-action-#{suffix}"
      )
      ConversationEscalations::Opening.call(
        conversation:,
        conversation_action: action,
        category: :other,
        priority: :normal,
        summary: "Customer-only deletion escalation.",
        opened_by_kind: :user,
        opened_by_user: actor,
        idempotency_key: "customer-escalation-#{suffix}"
      )
      action
    end

    def create_invoice_workflow(invoice:, actor:, suffix:)
      conversation = Conversation.for_invoice!(invoice:)
      action = ConversationActions::Proposal.record!(
        conversation:,
        action_type: :open_dispute,
        origin_kind: :user,
        created_by_user: actor,
        user_facing_summary: "Invoice deletion workflow.",
        idempotency_key: "invoice-action-#{suffix}"
      )
      hold = CollectionHolds::Placement.call(
        conversation:,
        conversation_action: action,
        reason: :dispute,
        placed_by_kind: :user,
        placed_by_user: actor,
        idempotency_key: "invoice-hold-#{suffix}"
      )
      escalation = ConversationEscalations::Opening.call(
        conversation:,
        conversation_action: action,
        collection_hold: hold,
        category: :dispute,
        priority: :high,
        summary: "Invoice deletion escalation.",
        opened_by_kind: :user,
        opened_by_user: actor,
        idempotency_key: "invoice-escalation-#{suffix}"
      )
      [ action, hold, escalation ]
    end
end

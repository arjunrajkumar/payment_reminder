require "test_helper"

class Conversations::ManualMatcherTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @actor = users(:arjun)
    @connection = email_connections(:paid_jar_gmail)
  end

  test "links every source in a Gmail thread to the invoice canonical conversation" do
    target = Conversation.for_invoice!(invoice: @invoice)
    source_one = create_source_conversation
    source_two = create_source_conversation
    first = create_review_message(source_one, provider_message_id: "manual-match-one")
    second = create_review_message(source_two, provider_message_id: "manual-match-two")
    source_one.update!(attention_required_at: first.received_at)
    source_two.update!(attention_required_at: second.received_at)

    result = Conversations::ManualMatcher.call(
      source_conversation: source_one,
      reviewed_message: first,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source_one),
      at: Time.zone.local(2026, 7, 23, 9)
    )

    assert_equal target, result
    assert_equal target, source_one.reload.canonical_conversation
    assert_equal target, source_two.reload.canonical_conversation
    assert_equal [ @invoice.id ], [ first.reload.invoice_id, second.reload.invoice_id ].uniq
    assert first.reviewed_at
    assert second.reviewed_at
    assert_equal @actor, first.reviewed_by_user
    assert_equal @actor, second.reviewed_by_user
    assert_equal second.received_at, target.reload.attention_required_at
    assert_nil source_one.attention_required_at
    assert_nil source_two.attention_required_at

    event = target.conversation_events.kind_conversation_manually_matched.sole
    assert_predicate event, :actor_kind_user?
    assert_equal @actor, event.actor_user
    assert_equal [ source_one.id, source_two.id ].sort, event.metadata.fetch("source_conversation_ids").sort
    assert_equal [ first.id, second.id ].sort, event.metadata.fetch("covered_message_ids").sort
  end

  test "same-target replay is idempotent and a different target is rejected" do
    source = create_source_conversation
    message = create_review_message(source, provider_message_id: "manual-match-replay")
    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source)
    )

    assert_no_difference -> { ConversationEvent.count } do
      assert_equal target, Conversations::ManualMatcher.call(
        source_conversation: source,
        reviewed_message: message,
        target_invoice: @invoice,
        actor_user: @actor,
        work_unit_token: conversation_work_unit_token(source.reload)
      )
    end

    other_invoice = @invoice.dup
    other_invoice.external_id = "other-match-target"
    other_invoice.number = "INV-OTHER"
    other_invoice.save!

    assert_no_difference [ -> { Conversation.count }, -> { ConversationEvent.count } ] do
      assert_raises Conversations::ManualMatcher::AlreadyLinked do
        Conversations::ManualMatcher.call(
          source_conversation: source,
          reviewed_message: message,
          target_invoice: other_invoice,
          actor_user: @actor,
          work_unit_token: conversation_work_unit_token(source.reload)
        )
      end
    end
    assert_equal target, source.reload.canonical_conversation
  end

  test "reloads a locked invoice before deriving the canonical customer" do
    stale_invoice = Invoice.find(@invoice.id)
    replacement_customer = @invoice.invoice_source.customers.create!(
      account: @account,
      external_id: "manual-match-replacement-customer",
      name: "Replacement invoice customer",
      email: "replacement-invoice-customer@example.com"
    )
    @invoice.update!(customer: replacement_customer)
    source = create_source_conversation
    message = create_review_message(source, provider_message_id: "stale-invoice-customer")

    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: stale_invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )

    assert_equal replacement_customer, target.customer
    assert_equal replacement_customer, target.invoice.customer
    assert_equal target, source.reload.canonical_conversation
    assert_predicate message.reload, :valid?
  end

  test "same-target replay stays idempotent when the thread includes clean messages" do
    source = create_source_conversation
    review_message = create_review_message(source, provider_message_id: "mixed-review-message")
    clean_message = create_clean_message(source, provider_message_id: "mixed-clean-message")
    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: review_message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )
    event_count = ConversationEvent.count

    assert_equal target, Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: review_message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )

    assert_equal event_count, ConversationEvent.count
    assert_equal @invoice, review_message.reload.invoice
    assert_equal @invoice, clean_message.reload.invoice
    assert review_message.reviewed_at
    assert_nil clean_message.reviewed_at
  end

  test "rejects an invoice whose customer contradicts the source customer" do
    other_customer = @invoice.invoice_source.customers.create!(
      account: @account,
      external_id: "manual-match-other-customer",
      name: "Other manual-match customer",
      email: "other-manual-match@example.com"
    )
    source = @account.conversations.create!(customer: other_customer)
    message = create_review_message(source, provider_message_id: "customer-conflict")

    error = assert_raises Conversations::ManualMatcher::InvalidSelection do
      Conversations::ManualMatcher.call(
        source_conversation: source,
        reviewed_message: message,
        target_invoice: @invoice,
        actor_user: @actor,
        work_unit_token: conversation_work_unit_token(source)
      )
    end

    assert_equal "This thread is already assigned to another customer.", error.message
    assert_nil source.reload.canonical_conversation
    assert_equal other_customer, source.customer
    assert_nil message.reload.invoice
  end

  test "supports audited customer-only assignment without inventing an invoice conversation" do
    source = create_source_conversation
    message = create_review_message(source, provider_message_id: "customer-only-match")

    result = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_customer: @invoice.customer,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )

    assert_equal source, result
    assert_equal @invoice.customer, source.reload.customer
    assert_nil source.canonical_conversation
    assert_nil message.reload.invoice
    assert message.reviewed_at
    assert_equal @actor, message.reviewed_by_user
    assert_predicate source.conversation_events.kind_conversation_manually_matched.sole,
      :actor_kind_user?
  end

  test "moves pending workflow records to the canonical invoice without rewriting snapshots" do
    source = create_source_conversation
    message = create_review_message(
      source,
      provider_message_id: "workflow-manual-match"
    )
    action = ConversationActions::Proposal.record!(
      conversation: source,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Review unmatched workflow evidence.",
      idempotency_key: "workflow-manual-match-action"
    )
    escalation = ConversationEscalations::Opening.call(
      conversation: source,
      category: :ambiguous,
      priority: :normal,
      summary: "Unmatched workflow escalation.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "workflow-manual-match-escalation"
    )
    original_revision = action.current_revision
    assert_nil original_revision.invoice_id
    assert_nil original_revision.customer_id

    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source)
    )

    assert_equal target, action.reload.conversation
    assert_equal target, escalation.reload.conversation
    assert_nil original_revision.reload.invoice_id
    assert_nil original_revision.customer_id
    assert_equal escalation.last_opened_at,
      target.reload.attention_required_at

    assert_equal action, ConversationActions::Proposal.record!(
      conversation: source,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Review unmatched workflow evidence.",
      idempotency_key: "workflow-manual-match-action"
    )
    assert_equal escalation, ConversationEscalations::Opening.call(
      conversation: source,
      category: :ambiguous,
      priority: :normal,
      summary: "Unmatched workflow escalation.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "workflow-manual-match-escalation"
    )
  end

  test "completed action and escalation retries survive workflow transfer" do
    source = create_source_conversation
    message = create_review_message(
      source,
      provider_message_id: "completed-workflow-transfer"
    )
    action = ConversationActions::Proposal.record!(
      conversation: source,
      source_message: message,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Approve before matching.",
      idempotency_key: "completed-transfer-action"
    )
    approval_key = "completed-transfer-approval"
    approval_token = ConversationActions::ActionSnapshot.token_for(
      action:,
      idempotency_key: approval_key
    )
    ConversationActions::Approval.call(
      action:,
      revision: action.current_revision,
      actor_user: @actor,
      idempotency_key: approval_key,
      snapshot_token: approval_token
    )
    escalation = ConversationEscalations::Opening.call(
      conversation: source,
      source_message: message,
      category: :ambiguous,
      priority: :normal,
      summary: "Resolve before matching.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "completed-transfer-escalation"
    )
    resolution_key = "completed-transfer-resolution"
    resolution_token = ConversationEscalations::EscalationSnapshot.token_for(
      escalation:,
      idempotency_key: resolution_key
    )
    escalation.resolve!(
      actor_user: @actor,
      resolution_note: "Resolved before matching.",
      idempotency_key: resolution_key,
      snapshot_token: resolution_token
    )

    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source)
    )

    assert_equal action, ConversationActions::Approval.call(
      action: action.reload,
      revision: action.current_revision,
      actor_user: @actor,
      idempotency_key: approval_key,
      snapshot_token: approval_token
    )
    assert_equal escalation, escalation.reload.resolve!(
      actor_user: @actor,
      resolution_note: "Resolved before matching.",
      idempotency_key: resolution_key,
      snapshot_token: resolution_token
    )
    assert_equal target, action.reload.conversation
    assert_equal target, escalation.reload.conversation
  end

  test "hidden same-thread workflow is owned by the visible work unit and retained on match" do
    first = create_source_conversation
    first_message = create_review_message(
      first,
      provider_message_id: "hidden-workflow-one"
    )
    hidden = create_source_conversation
    hidden_message = create_review_message(
      hidden,
      provider_message_id: "hidden-workflow-two"
    )
    action = ConversationActions::Proposal.record!(
      conversation: hidden,
      source_message: hidden_message,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Hidden sibling action.",
      idempotency_key: "hidden-sibling-action"
    )
    escalation = ConversationEscalations::Opening.call(
      conversation: hidden,
      source_message: hidden_message,
      category: :ambiguous,
      priority: :high,
      summary: "Hidden sibling escalation.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "hidden-sibling-escalation"
    )

    visible = Conversations::Inbox.call(account: @account).where(
      id: [ first.id, hidden.id ]
    ).to_a
    detail = Conversations::Detail.call(conversation: first)
    assert_equal [ first ], visible
    assert_includes detail.actions, action
    assert_includes detail.escalations, escalation
    assert first.reload.attention_required_at

    target = Conversations::ManualMatcher.call(
      source_conversation: first,
      reviewed_message: first_message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(first)
    )

    assert_equal target, action.reload.conversation
    assert_equal target, escalation.reload.conversation
    assert target.reload.attention_required_at
  end

  test "later invoice review ownership keeps hidden workflow controls usable" do
    source = create_source_conversation
    source_message = create_review_message(
      source,
      provider_message_id: "owner-change-source"
    )
    action = ConversationActions::Proposal.record!(
      conversation: source,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Workflow before invoice owner.",
      idempotency_key: "owner-change-action"
    )
    escalation = ConversationEscalations::Opening.call(
      conversation: source,
      category: :ambiguous,
      priority: :high,
      summary: "Escalation before invoice owner.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "owner-change-escalation"
    )
    invoice_conversation = Conversation.for_invoice!(invoice: @invoice)
    invoice_message = invoice_conversation.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "owner-change-invoice",
      provider_thread_id: source_message.provider_thread_id,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: source_message.received_at + 1.hour,
      matching_status: :matched,
      matching_method: :gmail_thread,
      review_required: true
    )
    Conversations::Attention.require_for_message!(invoice_message)
    Conversations::Attention.recompute!(conversation: invoice_conversation)

    detail = Conversations::Detail.call(conversation: invoice_conversation)
    assert_includes detail.actions, action
    assert_includes detail.escalations, escalation
    assert_equal invoice_conversation, action.reload.conversation
    assert_equal invoice_conversation, escalation.reload.conversation
    assert_nil source.reload.attention_required_at
    assert invoice_conversation.reload.attention_required_at

    revision_key = "owner-change-revision"
    revision = ConversationActions::Revision.record!(
      action:,
      author_kind: :user,
      author_user: @actor,
      user_facing_summary: "Workflow revised after invoice ownership.",
      rationale: "The invoice context is now known.",
      proposed_reply: {},
      idempotency_key: revision_key,
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action:,
        idempotency_key: revision_key
      )
    )
    assert_equal @invoice, revision.invoice
    assert_equal @invoice.customer, revision.customer

    hold = CollectionHolds::Placement.call(
      conversation: invoice_conversation,
      conversation_action: action,
      reason: :manual,
      placed_by_kind: :user,
      placed_by_user: @actor,
      idempotency_key: "owner-change-hold"
    )
    linked_escalation = ConversationEscalations::Opening.call(
      conversation: invoice_conversation,
      conversation_action: action,
      collection_hold: hold,
      category: :other,
      priority: :normal,
      summary: "Linked after invoice ownership.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "owner-change-linked-escalation"
    )
    assert_equal action, hold.conversation_action
    assert_equal hold, linked_escalation.collection_hold

    approval_key = "owner-change-approval"
    approval_token = ConversationActions::ActionSnapshot.token_for(
      action:,
      idempotency_key: approval_key
    )
    2.times do
      ConversationActions::Approval.call(
        action:,
        revision: action.current_revision,
        actor_user: @actor,
        idempotency_key: approval_key,
        snapshot_token: approval_token
      )
    end
    resolution_key = "owner-change-resolution"
    resolution_token = ConversationEscalations::EscalationSnapshot.token_for(
      escalation:,
      idempotency_key: resolution_key
    )
    2.times do
      escalation.resolve!(
        actor_user: @actor,
        resolution_note: "Handled from the invoice owner.",
        idempotency_key: resolution_key,
        snapshot_token: resolution_token
      )
    end
    linked_resolution_key = "owner-change-linked-resolution"
    linked_resolution_token = ConversationEscalations::EscalationSnapshot.token_for(
      escalation: linked_escalation,
      idempotency_key: linked_resolution_key
    )
    2.times do
      linked_escalation.resolve!(
        actor_user: @actor,
        resolution_note: "Linked escalation handled.",
        idempotency_key: linked_resolution_key,
        snapshot_token: linked_resolution_token
      )
    end

    assert_predicate action.reload, :status_approved?
    assert_predicate escalation.reload, :status_resolved?
    assert_predicate linked_escalation.reload, :status_resolved?
    assert_equal invoice_message.received_at,
      invoice_conversation.reload.attention_required_at
    assert_nil source.reload.attention_required_at
  end

  test "rejects matching a Gmail review work unit to a second invoice" do
    invoice_owner = Conversation.for_invoice!(invoice: @invoice)
    invoice_message = invoice_owner.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      provider_message_id: "split-invoice-owner",
      provider_thread_id: "manual-match-thread",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 9),
      matching_status: :matched,
      matching_method: :gmail_thread,
      review_required: true
    )
    source = create_source_conversation
    source_message = create_review_message(
      source,
      provider_message_id: "split-invoice-source"
    )
    source.update!(attention_required_at: source_message.received_at)
    action = ConversationActions::Proposal.record!(
      conversation: source,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Must remain with the original Gmail work unit.",
      idempotency_key: "split-invoice-action"
    )
    escalation = ConversationEscalations::Opening.call(
      conversation: source,
      category: :ambiguous,
      priority: :high,
      summary: "Must not move across invoices.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "split-invoice-escalation"
    )
    other_invoice = @invoice.dup
    other_invoice.external_id = "split-invoice-target"
    other_invoice.number = "INV-SPLIT-TARGET"
    other_invoice.save!
    other_owner = Conversation.for_invoice!(invoice: other_invoice)
    counts = {
      conversations: Conversation.count,
      messages: ConversationMessage.count,
      events: ConversationEvent.count,
      actions: ConversationAction.count,
      escalations: ConversationEscalation.count
    }
    assert_nil source.reload.attention_required_at
    action_conversation = action.conversation
    escalation_conversation = escalation.conversation

    assert_raises Conversations::ManualMatcher::InvalidSelection do
      Conversations::ManualMatcher.call(
        source_conversation: source,
        reviewed_message: source_message,
        target_invoice: other_invoice,
        actor_user: @actor,
        work_unit_token: conversation_work_unit_token(source)
      )
    end

    assert_equal counts.fetch(:conversations), Conversation.count
    assert_equal counts.fetch(:messages), ConversationMessage.count
    assert_equal counts.fetch(:events), ConversationEvent.count
    assert_equal counts.fetch(:actions), ConversationAction.count
    assert_equal counts.fetch(:escalations), ConversationEscalation.count
    assert_nil source.reload.canonical_conversation
    assert_nil source_message.reload.invoice
    assert_predicate source_message, :awaiting_review?
    assert_nil source.attention_required_at
    assert_equal action_conversation, action.reload.conversation
    assert_equal escalation_conversation, escalation.reload.conversation
    assert_not Conversations::ReviewWorkUnit.same_work_unit?(
      left: invoice_owner,
      right: other_owner
    )

    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: source_message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source)
    )
    assert_equal invoice_owner, target
    assert_equal target, Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: source_message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )
  end

  test "rejects a second invoice when the existing owner is reached through a linked source" do
    first_owner = Conversation.for_invoice!(invoice: @invoice)
    linked_source = create_source_conversation
    linked_message = create_review_message(
      linked_source,
      provider_message_id: "linked-first-invoice"
    )
    linked_source.update!(canonical_conversation: first_owner)
    linked_message.update!(invoice: @invoice)

    second_source = create_source_conversation
    second_message = create_review_message(
      second_source,
      provider_message_id: "linked-second-source"
    )
    second_source.update!(attention_required_at: second_message.received_at)
    action = ConversationActions::Proposal.record!(
      conversation: second_source,
      source_message: second_message,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Keep the linked invoice owner.",
      idempotency_key: "linked-owner-conflict-action"
    )
    escalation = ConversationEscalations::Opening.call(
      conversation: second_source,
      source_message: second_message,
      category: :ambiguous,
      priority: :high,
      summary: "Keep the linked invoice escalation.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "linked-owner-conflict-escalation"
    )
    other_invoice = @invoice.dup
    other_invoice.external_id = "linked-owner-conflict"
    other_invoice.number = "INV-LINKED-CONFLICT"
    other_invoice.save!
    other_owner = Conversation.for_invoice!(invoice: other_invoice)
    before = manual_match_state(
      conversations: [ first_owner, linked_source, second_source, other_owner ],
      messages: [ linked_message, second_message ],
      action:,
      escalation:
    )

    error = assert_raises Conversations::ManualMatcher::InvalidSelection do
      Conversations::ManualMatcher.call(
        source_conversation: second_source,
        reviewed_message: second_message,
        target_invoice: other_invoice,
        actor_user: @actor,
        work_unit_token: conversation_work_unit_token(second_source)
      )
    end

    assert_equal "This Gmail thread is already linked to another invoice.",
      error.message
    assert_equal before, manual_match_state(
      conversations: [ first_owner, linked_source, second_source, other_owner ],
      messages: [ linked_message, second_message ],
      action:,
      escalation:
    )
  end

  test "linked-owner rejection rolls back its savepoint when an ambient transaction rescues it" do
    first_owner = Conversation.for_invoice!(invoice: @invoice)
    linked_source = create_source_conversation
    linked_message = create_review_message(
      linked_source,
      provider_message_id: "ambient-linked-first"
    )
    linked_source.update!(canonical_conversation: first_owner)
    linked_message.update!(invoice: @invoice)
    second_source = create_source_conversation
    second_message = create_review_message(
      second_source,
      provider_message_id: "ambient-linked-second"
    )
    other_invoice = @invoice.dup
    other_invoice.external_id = "ambient-linked-conflict"
    other_invoice.number = "INV-AMBIENT-CONFLICT"
    other_invoice.save!
    other_owner = Conversation.for_invoice!(invoice: other_invoice)
    before = manual_match_state(
      conversations: [ first_owner, linked_source, second_source, other_owner ],
      messages: [ linked_message, second_message ]
    )

    Conversation.transaction do
      begin
        Conversations::ManualMatcher.call(
          source_conversation: second_source,
          reviewed_message: second_message,
          target_invoice: other_invoice,
          actor_user: @actor,
          work_unit_token: conversation_work_unit_token(second_source)
        )
      rescue Conversations::ManualMatcher::InvalidSelection
        # The surrounding transaction deliberately continues.
      end

      assert_equal before, manual_match_state(
        conversations: [ first_owner, linked_source, second_source, other_owner ],
        messages: [ linked_message, second_message ]
      )
    end
  end

  test "source-less workflow retries remain exact after manual matching" do
    source = create_source_conversation
    message = create_review_message(
      source,
      provider_message_id: "source-less-workflow-retry"
    )
    action_key = "source-less-matched-action"
    escalation_key = "source-less-matched-escalation"
    action = ConversationActions::Proposal.record!(
      conversation: source,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Retry after matching.",
      idempotency_key: action_key
    )
    escalation = ConversationEscalations::Opening.call(
      conversation: source,
      category: :other,
      priority: :normal,
      summary: "Retry escalation after matching.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: escalation_key
    )
    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source)
    )

    assert_equal action, ConversationActions::Proposal.record!(
      conversation: target,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Retry after matching.",
      idempotency_key: action_key
    )
    assert_equal escalation, ConversationEscalations::Opening.call(
      conversation: target,
      category: :other,
      priority: :normal,
      summary: "Retry escalation after matching.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: escalation_key
    )
  end

  test "corrects a no-match review to an audited idempotent manual match" do
    source = create_source_conversation
    message = create_review_message(
      source,
      provider_message_id: "corrected-manual-match"
    )
    source.update!(attention_required_at: message.received_at)
    ConversationMessages::Review.complete!(
      conversation: source,
      message:,
      actor_user: @actor,
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(source)
    )
    assert_predicate message.reload, :review_outcome_no_match_needed?
    assert_nil source.reload.attention_required_at

    target = Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source)
    )

    assert_predicate message.reload, :review_outcome_manual_match?
    assert_predicate message, :trusted_matching_anchor?
    assert_equal message.received_at, target.reload.attention_required_at
    correction = message.conversation_events
      .kind_conversation_message_review_corrected
      .sole
    assert_equal "no_match_needed", correction.metadata.fetch("previous_outcome")
    assert_equal "manual_match", correction.metadata.fetch("outcome")
    event_count = ConversationEvent.count

    assert_equal target, Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: message,
      target_invoice: @invoice,
      actor_user: @actor,
      work_unit_token: conversation_work_unit_token(source.reload)
    )
    assert_equal event_count, ConversationEvent.count
  end

  private
    def manual_match_state(conversations:, messages:, action: nil, escalation: nil)
      {
        conversation_count: Conversation.count,
        message_count: ConversationMessage.count,
        event_count: ConversationEvent.count,
        action_count: ConversationAction.count,
        escalation_count: ConversationEscalation.count,
        conversations: conversations.index_with do |conversation|
          conversation.reload.attributes.slice(
            "invoice_id",
            "customer_id",
            "canonical_conversation_id",
            "attention_required_at"
          )
        end,
        messages: messages.index_with do |message|
          message.reload.attributes.slice(
            "invoice_id",
            "reviewed_at",
            "reviewed_by_user_id",
            "review_outcome"
          )
        end,
        action_conversation_id: action&.reload&.conversation_id,
        escalation_conversation_id: escalation&.reload&.conversation_id
      }
    end

    def create_source_conversation
      @account.conversations.create!
    end

    def create_review_message(conversation, provider_message_id:)
      conversation.conversation_messages.create!(
        account: @account,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "manual-match-thread",
        internet_message_id: "<#{provider_message_id}@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.zone.local(2026, 7, 22, provider_message_id.end_with?("two") ? 11 : 10),
        from_address: @invoice.customer.email,
        matching_status: :unmatched,
        matching_method: :none,
        review_required: true,
        review_reasons: [ "invoice_unmatched" ]
      )
    end

    def create_clean_message(conversation, provider_message_id:)
      conversation.conversation_messages.create!(
        account: @account,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "manual-match-thread",
        internet_message_id: "<#{provider_message_id}@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.zone.local(2026, 7, 22, 12),
        from_address: @invoice.customer.email,
        matching_status: :matched,
        matching_method: :customer_only,
        review_required: false
      )
    end
end

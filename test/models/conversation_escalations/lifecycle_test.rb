require "test_helper"

class ConversationEscalations::LifecycleTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @actor = users(:arjun)
    @escalation = open_escalation
  end

  test "open resolve and reopen are independently audited and drive attention" do
    assert_equal @escalation.last_opened_at,
      @conversation.reload.attention_required_at

    resolve_token = snapshot("resolve-escalation")
    @escalation.resolve!(
      actor_user: @actor,
      resolution_note: "Customer clarified the issue.",
      idempotency_key: "resolve-escalation",
      snapshot_token: resolve_token
    )

    assert_predicate @escalation.reload, :status_resolved?
    assert_nil @conversation.reload.attention_required_at

    reopen_token = snapshot("reopen-escalation")
    @escalation.reopen!(
      actor_user: @actor,
      idempotency_key: "reopen-escalation",
      snapshot_token: reopen_token
    )

    assert_predicate @escalation.reload, :status_open?
    assert_nil @escalation.resolved_at
    assert_equal @escalation.last_opened_at,
      @conversation.reload.attention_required_at
    assert_equal 1, @conversation.conversation_events
      .kind_conversation_escalation_resolved.count
    assert_equal 1, @conversation.conversation_events
      .kind_conversation_escalation_reopened.count
  end

  test "exact transition retries do not duplicate events" do
    token = snapshot("resolve-once")

    2.times do
      @escalation.resolve!(
        actor_user: @actor,
        resolution_note: "Resolved once.",
        idempotency_key: "resolve-once",
        snapshot_token: token
      )
    end

    assert_equal 1, @conversation.conversation_events
      .kind_conversation_escalation_resolved.count
  end

  test "mark handled cannot hide an open escalation" do
    @conversation.clear_attention!(
      actor_user: @actor,
      metadata: { "outcome" => "handled" },
      visible_message_ids: []
    )
    Conversations::Attention.recompute!(conversation: @conversation)

    assert_equal @escalation.last_opened_at,
      @conversation.reload.attention_required_at
  end

  test "resolving an escalation and releasing a hold remain independent" do
    hold = CollectionHolds::Placement.call(
      conversation: @conversation,
      reason: :dispute,
      placed_by_kind: :user,
      placed_by_user: @actor,
      idempotency_key: "independent-escalation-hold"
    )
    @escalation.resolve!(
      actor_user: @actor,
      resolution_note: "Escalation review complete.",
      idempotency_key: "independent-resolution",
      snapshot_token: snapshot("independent-resolution")
    )

    assert_predicate hold.reload, :status_active?

    release_key = "independent-hold-release"
    hold.release!(
      actor_user: @actor,
      idempotency_key: release_key,
      snapshot_token: CollectionHolds::HoldSnapshot.token_for(
        hold:,
        idempotency_key: release_key
      )
    )

    assert_predicate @escalation.reload, :status_resolved?
  end

  test "multiple resolution cycles retain every rationale in immutable events" do
    2.times do |index|
      resolution_key = "resolution-cycle-#{index}"
      @escalation.resolve!(
        actor_user: @actor,
        resolution_note: "Resolution rationale #{index}.",
        idempotency_key: resolution_key,
        snapshot_token: snapshot(resolution_key)
      )
      reopen_key = "reopen-cycle-#{index}"
      @escalation.reopen!(
        actor_user: @actor,
        idempotency_key: reopen_key,
        snapshot_token: snapshot(reopen_key)
      )
    end

    resolved_events = @conversation.conversation_events
      .kind_conversation_escalation_resolved
      .order(:id)
    assert_equal [
      "Resolution rationale 0.",
      "Resolution rationale 1."
    ], resolved_events.map { |event| event.metadata["rationale"] }
    assert_equal [
      "Resolution rationale 0.",
      "Resolution rationale 1."
    ], @conversation.conversation_events
      .kind_conversation_escalation_reopened
      .order(:id)
      .map { |event| event.metadata.dig("previous_resolution", "resolution_note") }
  end

  test "customer correction does not block resolve reopen or exact retries" do
    original_customer = @escalation.customer
    replacement = @invoice.invoice_source.customers.create!(
      account: @invoice.account,
      external_id: "corrected-escalation-customer",
      name: "Corrected escalation customer",
      email: "corrected-escalation@example.com"
    )
    @invoice.update!(customer: replacement)
    resolve_key = "resolve-after-correction"
    resolve_token = snapshot(resolve_key)

    2.times do
      @escalation.resolve!(
        actor_user: @actor,
        resolution_note: "Resolved against the historical snapshot.",
        idempotency_key: resolve_key,
        snapshot_token: resolve_token
      )
    end
    reopen_key = "reopen-after-correction"
    reopen_token = snapshot(reopen_key)
    2.times do
      @escalation.reopen!(
        actor_user: @actor,
        idempotency_key: reopen_key,
        snapshot_token: reopen_token
      )
    end

    assert_equal original_customer, @escalation.reload.customer
    assert_predicate @escalation, :status_open?
  end

  test "direct updates cannot rewrite escalation provenance or lifecycle" do
    assert_raises ActiveRecord::ReadOnlyRecord do
      @escalation.update!(priority: :urgent)
    end
    assert_raises ActiveRecord::ReadOnlyRecord do
      @escalation.update!(
        status: :resolved,
        resolved_by_user: @actor,
        resolved_at: Time.current,
        resolution_note: "Bypassed audit."
      )
    end
  end

  test "multiple escalations can cite one source message with complete audit events" do
    source_message = @invoice.conversation_messages.create!(
      account: @invoice.account,
      conversation: @conversation,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current
    )
    2.times do |index|
      ConversationEscalations::Opening.call(
        conversation: @conversation,
        source_message:,
        category: :other,
        priority: :normal,
        summary: "Same-source escalation #{index}.",
        opened_by_kind: :user,
        opened_by_user: @actor,
        idempotency_key: "same-source-escalation-#{index}"
      )
    end

    assert_equal 3, @conversation.conversation_events
      .kind_conversation_escalated.count
    assert_empty @conversation.conversation_events
      .kind_conversation_escalated
      .where.not(conversation_message_id: nil)
  end

  test "validation bypass and public internal APIs cannot bypass escalation audit" do
    @escalation.status = :resolved
    @escalation.resolved_by_user = @actor
    @escalation.resolved_at = Time.current
    @escalation.resolution_note = "Bypassed."

    assert_raises ActiveRecord::ReadOnlyRecord do
      @escalation.save!(validate: false)
    end
    other_invoice = @invoice.dup
    other_invoice.external_id = "private-transfer-escalation"
    other_invoice.number = "INV-PRIVATE-ESCALATION"
    other_invoice.save!
    assert_raises NoMethodError do
      @escalation.transfer_to_conversation!(
        Conversation.for_invoice!(invoice: other_invoice)
      )
    end
    assert_raises NoMethodError do
      @escalation.destroy_for_parent!
    end
    assert_predicate @escalation.reload, :status_open?
    assert_empty @conversation.conversation_events
      .kind_conversation_escalation_resolved
  end

  test "source-less escalation idempotency is scoped to its originating work unit" do
    key = "source-less-origin-escalation"
    first = ConversationEscalations::Opening.call(
      conversation: @conversation,
      category: :other,
      priority: :normal,
      summary: "Source-less origin.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: key
    )
    assert_equal first, ConversationEscalations::Opening.call(
      conversation: @conversation,
      category: :other,
      priority: :normal,
      summary: "Source-less origin.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: key
    )

    unrelated = @escalation.account.conversations.create!
    assert_raises ConversationEscalations::IdempotencyConflict do
      ConversationEscalations::Opening.call(
        conversation: unrelated,
        category: :other,
        priority: :normal,
        summary: "Source-less origin.",
        opened_by_kind: :user,
        opened_by_user: @actor,
        idempotency_key: key
      )
    end

    other_invoice = @invoice.dup
    other_invoice.external_id = "source-less-escalation-invoice"
    other_invoice.number = "INV-SOURCE-LESS-ESCALATION"
    other_invoice.save!
    assert_raises ConversationEscalations::IdempotencyConflict do
      ConversationEscalations::Opening.call(
        conversation: Conversation.for_invoice!(invoice: other_invoice),
        category: :other,
        priority: :normal,
        summary: "Source-less origin.",
        opened_by_kind: :user,
        opened_by_user: @actor,
        idempotency_key: key
      )
    end
  end

  test "a preconstructed opening resolves an invoice owner created before mutation" do
    account = @invoice.account
    connection = email_connections(:paid_jar_gmail)
    source_conversation = account.conversations.create!
    source_message = source_conversation.conversation_messages.create!(
      account:,
      email_connection: connection,
      email_connection_generation: connection.credential_generation,
      provider_account_id: connection.provider_account_id,
      provider_message_id: "preconstructed-escalation-source",
      provider_thread_id: "preconstructed-escalation-thread",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 24, 10),
      matching_status: :unmatched,
      matching_method: :none,
      review_required: true
    )
    opening = ConversationEscalations::Opening.new(
      conversation: source_conversation,
      source_message:,
      category: :ambiguous,
      priority: :high,
      summary: "Resolve against the eventual owner.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "preconstructed-escalation"
    )
    invoice_owner = Conversation.for_invoice!(invoice: @invoice)
    invoice_owner.conversation_messages.create!(
      account:,
      invoice: @invoice,
      email_connection: connection,
      email_connection_generation: connection.credential_generation,
      provider_account_id: connection.provider_account_id,
      provider_message_id: "preconstructed-escalation-owner",
      provider_thread_id: source_message.provider_thread_id,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: source_message.received_at + 1.minute,
      matching_status: :matched,
      matching_method: :gmail_thread,
      review_required: true
    )

    escalation = opening.call

    assert_equal invoice_owner, escalation.conversation
    assert_equal @invoice, escalation.invoice
    assert_equal @invoice.customer, escalation.customer
    assert_equal source_message.received_at + 1.minute,
      invoice_owner.reload.attention_required_at
    assert_nil source_conversation.reload.attention_required_at
    assert_equal escalation, opening.call
  end

  private
    def open_escalation
      ConversationEscalations::Opening.call(
        conversation: @conversation,
        category: :dispute,
        priority: :high,
        summary: "Customer disputes the invoice.",
        details: "The customer asked for a human review.",
        opened_by_kind: :user,
        opened_by_user: @actor,
        idempotency_key: "escalation-one"
      )
    end

    def snapshot(idempotency_key)
      ConversationEscalations::EscalationSnapshot.token_for(
        escalation: @escalation.reload,
        idempotency_key:
      )
    end
end

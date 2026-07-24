require "test_helper"

class ConversationActions::ProposalTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @actor = users(:arjun)
    @source_message = create_source_message
  end

  test "records a canonical action and immutable revision one atomically" do
    assert_difference [
      -> { ConversationAction.count },
      -> { ConversationActionRevision.count },
      -> { ConversationEvent.kind_conversation_action_created.count }
    ], 1 do
      @action = record_proposal
    end

    assert_equal @conversation, @action.conversation
    assert_equal @source_message, @action.source_message
    assert_predicate @action, :status_pending_approval?
    assert_equal @actor, @action.created_by_user
    assert_equal 1, @action.current_revision.revision_number
    assert_equal @invoice, @action.current_revision.invoice
    assert_equal @invoice.customer, @action.current_revision.customer
    assert_equal "Confirm the customer payment date.", @action.current_revision.user_facing_summary
    assert_equal({ "promised_on" => "2026-08-05" }, @action.current_revision.arguments)
  end

  test "canonicalizes a linked source conversation and accepts its source message" do
    linked = @account.conversations.create!(canonical_conversation: @conversation)
    source = create_source_message(conversation: linked)

    action = record_proposal(
      conversation: linked,
      source_message: source,
      idempotency_key: "linked-action"
    )

    assert_equal @conversation, action.conversation
    assert_equal source, action.source_message
  end

  test "a preconstructed proposal resolves an invoice owner created before mutation" do
    source_conversation = @account.conversations.create!
    source_message = source_conversation.conversation_messages.create!(
      account: @account,
      email_connection: email_connections(:paid_jar_gmail),
      email_connection_generation: email_connections(:paid_jar_gmail)
        .credential_generation,
      provider_account_id: email_connections(:paid_jar_gmail)
        .provider_account_id,
      provider_message_id: "preconstructed-action-source",
      provider_thread_id: "preconstructed-action-thread",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 24, 9),
      matching_status: :unmatched,
      matching_method: :none,
      review_required: true
    )
    proposal = ConversationActions::Proposal.new(
      conversation: source_conversation,
      source_message:,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Resolve against the eventual owner.",
      idempotency_key: "preconstructed-action"
    )
    invoice_owner = Conversation.for_invoice!(invoice: @invoice)
    owner_message = invoice_owner.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: email_connections(:paid_jar_gmail),
      email_connection_generation: email_connections(:paid_jar_gmail)
        .credential_generation,
      provider_account_id: email_connections(:paid_jar_gmail)
        .provider_account_id,
      provider_message_id: "preconstructed-action-owner",
      provider_thread_id: source_message.provider_thread_id,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: source_message.received_at + 1.minute,
      matching_status: :matched,
      matching_method: :gmail_thread,
      review_required: true
    )

    action = proposal.record!

    assert_equal invoice_owner, action.conversation
    assert_equal @invoice, action.current_revision.invoice
    assert_equal @invoice.customer, action.current_revision.customer
    event = invoice_owner.conversation_events
      .kind_conversation_action_created
      .detect { |item| item.metadata["conversation_action_id"] == action.id }
    assert_equal invoice_owner, event.conversation
    assert_equal owner_message.received_at,
      invoice_owner.reload.attention_required_at
    assert_nil source_conversation.reload.attention_required_at
    assert_equal owner_message, owner_message.reload
    assert_equal action, proposal.record!
  end

  test "an exact proposal retry returns the original action without another event" do
    first = record_proposal

    assert_no_difference [
      -> { ConversationAction.count },
      -> { ConversationActionRevision.count },
      -> { ConversationEvent.count }
    ] do
      assert_equal first, record_proposal
    end
  end

  test "an exact proposal retry still returns the envelope after later revisions" do
    action = record_proposal
    revision_key = "later-human-revision"
    ConversationActions::Revision.record!(
      action:,
      author_kind: :user,
      author_user: @actor,
      user_facing_summary: "A later human edit.",
      rationale: nil,
      proposed_reply: {},
      idempotency_key: revision_key,
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action:,
        idempotency_key: revision_key
      )
    )

    assert_equal action, record_proposal
  end

  test "reusing a proposal key for different immutable input conflicts" do
    record_proposal

    assert_raises ConversationActions::IdempotencyConflict do
      record_proposal(user_facing_summary: "Different proposal")
    end
  end

  test "rejects cross-account actors and unrelated source messages" do
    other_account = Account.create!(name: "Other action account")
    other_user = other_account.users.create!(name: "Other actor")

    assert_raises ActiveRecord::RecordNotFound do
      record_proposal(created_by_user: other_user)
    end

    other_conversation = @account.conversations.create!
    unrelated = create_source_message(conversation: other_conversation)
    assert_raises ActiveRecord::RecordNotFound do
      record_proposal(source_message: unrelated, idempotency_key: "unrelated-source")
    end
  end

  test "revision content cannot be updated or independently deleted" do
    revision = record_proposal.current_revision

    assert_raises ActiveRecord::ReadOnlyRecord do
      revision.update!(user_facing_summary: "Rewritten history")
    end
    assert_raises ActiveRecord::DeleteRestrictionError do
      revision.destroy!
    end
  end

  test "multiple actions can cite one source message with complete audit events" do
    first = record_proposal
    second = record_proposal(
      idempotency_key: "proposal-two-same-source",
      user_facing_summary: "A second action from the same email."
    )

    assert_not_equal first, second
    assert_equal 2, @conversation.conversation_events
      .kind_conversation_action_created.count
    assert_empty @conversation.conversation_events
      .kind_conversation_action_created
      .where.not(conversation_message_id: nil)
  end

  test "exact retry ignores a later invoice customer correction" do
    action = record_proposal
    original_customer = action.current_revision.customer
    replacement = @invoice.invoice_source.customers.create!(
      account: @account,
      external_id: "corrected-action-customer",
      name: "Corrected action customer",
      email: "corrected-action@example.com"
    )
    @invoice.update!(customer: replacement)

    assert_equal action, record_proposal
    assert_equal original_customer, action.current_revision.reload.customer
  end

  test "exact retry repairs attention after post-persistence failure" do
    singleton = Conversations::Attention.singleton_class
    original = singleton.instance_method(:recompute!)
    calls = 0
    singleton.define_method(:recompute!) do |**attributes|
      calls += 1
      raise "attention failed" if calls == 1

      original.bind_call(self, **attributes)
    end
    begin
      assert_raises(RuntimeError) { record_proposal }
      action = record_proposal

      assert_predicate action, :status_pending_approval?
      assert_equal action.current_revision.created_at,
        @conversation.reload.attention_required_at
    ensure
      singleton.define_method(:recompute!, original)
    end
  end

  test "source-less idempotency is scoped to the originating work unit" do
    key = "source-less-origin-action"
    action = record_proposal(
      source_message: nil,
      idempotency_key: key
    )
    assert_equal action, record_proposal(
      source_message: nil,
      idempotency_key: key
    )

    unrelated = @account.conversations.create!
    assert_raises ConversationActions::IdempotencyConflict do
      record_proposal(
        conversation: unrelated,
        source_message: nil,
        idempotency_key: key
      )
    end

    other_invoice = @invoice.dup
    other_invoice.external_id = "source-less-other-invoice"
    other_invoice.number = "INV-SOURCE-LESS-OTHER"
    other_invoice.save!
    assert_raises ConversationActions::IdempotencyConflict do
      record_proposal(
        conversation: Conversation.for_invoice!(invoice: other_invoice),
        source_message: nil,
        idempotency_key: key
      )
    end
  end

  private
    def record_proposal(
      conversation: @conversation,
      source_message: @source_message,
      created_by_user: @actor,
      user_facing_summary: "Confirm the customer payment date.",
      idempotency_key: "proposal-one"
    )
      ConversationActions::Proposal.record!(
        conversation:,
        source_message:,
        action_type: :record_payment_promise,
        origin_kind: :user,
        created_by_user:,
        user_facing_summary:,
        rationale: "The customer supplied a date.",
        arguments: { "promised_on" => "2026-08-05" },
        proposed_reply: {
          "subject" => "Payment date confirmed",
          "body" => "Thanks, we noted your payment date."
        },
        idempotency_key:
      )
    end

    def create_source_message(conversation: @conversation)
      conversation.conversation_messages.create!(
        account: @account,
        invoice: conversation.canonical.invoice,
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.current,
        from_address: @invoice.customer.email,
        matching_status: :matched,
        matching_method: :invoice_reference
      )
    end
end

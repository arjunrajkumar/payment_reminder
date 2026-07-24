require "test_helper"

class Conversations::InboxTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @invoice = invoices(:xero_invoice)
  end

  test "returns nonempty canonical conversations by latest message activity" do
    older = Conversation.for_invoice!(invoice: @invoice)
    create_message(
      conversation: older,
      direction: :outbound,
      kind: :scheduled_reminder,
      status: :sent,
      sent_at: Time.zone.local(2026, 7, 22, 9)
    )
    newer = @account.conversations.create!
    create_message(
      conversation: newer,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 10)
    )
    @account.conversations.create!
    linked_source = @account.conversations.create!(canonical_conversation: older)
    create_message(
      conversation: linked_source,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 11),
      invoice: @invoice
    )

    conversations = Conversations::Inbox.call(account: @account, filter: :all).to_a

    assert_equal [ older, newer ], conversations
  end

  test "filters shared attention and review work at canonical conversation level" do
    attention = Conversation.for_invoice!(invoice: @invoice)
    attention.update!(attention_required_at: Time.zone.local(2026, 7, 22, 10))
    create_message(
      conversation: attention,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 10)
    )

    review = @account.conversations.create!
    create_message(
      conversation: review,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 11),
      review_required: true
    )
    review.update!(attention_required_at: Time.zone.local(2026, 7, 22, 11))

    outbound_only = @account.conversations.create!(
      customer: @invoice.customer
    )
    create_message(
      conversation: outbound_only,
      direction: :outbound,
      kind: :manual_email,
      status: :sent,
      sent_at: Time.zone.local(2026, 7, 22, 12)
    )

    assert_equal(
      [ review, attention ],
      Conversations::Inbox.call(account: @account, filter: :needs_attention).to_a
    )
    assert_equal(
      [ review ],
      Conversations::Inbox.call(account: @account, filter: :needs_review).to_a
    )
    assert_equal 2, Conversations::AttentionSummary.call(account: @account).count
  end

  test "collapses one unresolved mailbox thread into one review item" do
    first_conversation = @account.conversations.create!
    second_conversation = @account.conversations.create!
    first = create_message(
      conversation: first_conversation,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 10),
      review_required: true,
      provider_thread_id: "shared-review-thread",
      from_address: "review-sender@example.com"
    )
    second = create_message(
      conversation: second_conversation,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 11),
      review_required: true,
      provider_thread_id: "shared-review-thread",
      from_address: "review-sender@example.com"
    )

    conversations = Conversations::Inbox.call(
      account: @account,
      filter: :needs_review
    ).to_a
    entries = Conversations::Inbox.decorate(
      account: @account,
      conversations:
    )

    assert_equal [ first_conversation ], conversations
    assert_equal second, entries.sole.latest_message
    assert_equal second,
      Conversations::Detail.call(
        conversation: conversations.sole
      ).timeline.messages.last
    assert_equal "review-sender@example.com", entries.sole.latest_inbound_sender
    assert entries.sole.needs_review
    assert first.awaiting_review?
  end

  test "invoice review and an unlinked same-thread sibling form one visible work unit" do
    canonical = Conversation.for_invoice!(invoice: @invoice)
    sibling_conversation = @account.conversations.create!
    canonical_message = create_message(
      conversation: canonical,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 10),
      review_required: true,
      provider_thread_id: "invoice-review-thread",
      from_address: @invoice.customer.email
    )
    sibling_message = create_message(
      conversation: sibling_conversation,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 11),
      review_required: true,
      provider_thread_id: "invoice-review-thread",
      from_address: @invoice.customer.email
    )

    conversations = Conversations::Inbox.call(
      account: @account,
      filter: :needs_review
    ).to_a
    entries = Conversations::Inbox.decorate(
      account: @account,
      conversations:
    )
    visible_messages = Conversations::Detail.call(
      conversation: canonical
    ).timeline.messages

    assert_equal [ canonical ], conversations
    assert_equal sibling_message, entries.sole.latest_message
    assert_equal [ canonical_message, sibling_message ], visible_messages

    covered = ConversationMessages::Review.complete!(
      conversation: canonical,
      message: canonical_message,
      actor_user: users(:arjun),
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(canonical)
    )

    assert_equal visible_messages, covered
    assert covered.none?(&:awaiting_review?)
    assert_empty Conversations::Inbox.call(
      account: @account,
      filter: :needs_review
    )
  end

  test "a linked-source review and later unlinked sibling stay one canonical work unit" do
    canonical = Conversation.for_invoice!(invoice: @invoice)
    source = @account.conversations.create!
    source_message = create_message(
      conversation: source,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 10),
      review_required: true,
      provider_thread_id: "linked-source-review-thread",
      from_address: @invoice.customer.email
    )
    Conversations::ManualMatcher.call(
      source_conversation: source,
      reviewed_message: source_message,
      target_invoice: @invoice,
      actor_user: users(:arjun),
      work_unit_token: conversation_work_unit_token(source)
    )
    sibling = @account.conversations.create!
    sibling_message = create_message(
      conversation: sibling,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 11),
      review_required: true,
      provider_thread_id: "linked-source-review-thread",
      from_address: @invoice.customer.email
    )

    conversations = Conversations::Inbox.call(
      account: @account,
      filter: :needs_review
    ).to_a
    entries = Conversations::Inbox.decorate(
      account: @account,
      conversations:
    )
    visible_messages = Conversations::Detail.call(
      conversation: canonical
    ).timeline.messages

    assert_equal [ canonical ], conversations
    assert_equal sibling_message, entries.sole.latest_message
    assert_equal [ source_message, sibling_message ], visible_messages

    covered = ConversationMessages::Review.complete!(
      conversation: canonical,
      message: sibling_message,
      actor_user: users(:arjun),
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(canonical)
    )

    assert_equal [ sibling_message ], covered
    assert_empty Conversations::Inbox.call(
      account: @account,
      filter: :needs_review
    )

    another_sibling = @account.conversations.create!
    another_message = create_message(
      conversation: another_sibling,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.zone.local(2026, 7, 22, 12),
      review_required: true,
      provider_thread_id: "linked-source-review-thread",
      from_address: @invoice.customer.email
    )
    covered_from_linked_source = ConversationMessages::Review.complete!(
      conversation: canonical,
      message: source_message,
      actor_user: users(:arjun),
      outcome: :no_match_needed,
      work_unit_token: conversation_work_unit_token(canonical)
    )

    assert_equal [ another_message ], covered_from_linked_source
    assert_empty Conversations::Inbox.call(
      account: @account,
      filter: :needs_review
    )
  end

  test "late-owner workflow mutations reorder the visible row before pagination" do
    source = @account.conversations.create!
    source_message = create_message(
      conversation: source,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 4.days.ago,
      review_required: true,
      provider_thread_id: "late-owner-ordering"
    )
    action = ConversationActions::Proposal.record!(
      conversation: source,
      action_type: :other,
      origin_kind: :user,
      created_by_user: users(:arjun),
      user_facing_summary: "Older hidden workflow.",
      idempotency_key: "late-owner-ordering-action",
      at: 4.days.ago
    )
    owner = Conversation.for_invoice!(invoice: @invoice)
    create_message(
      conversation: owner,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 3.days.ago,
      review_required: true,
      provider_thread_id: source_message.provider_thread_id,
      invoice: @invoice
    )
    other = @account.conversations.create!
    create_message(
      conversation: other,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 1.day.ago
    )
    Conversations::Detail.call(conversation: owner)
    revision_key = "late-owner-ordering-revision"
    ConversationActions::Revision.record!(
      action:,
      author_kind: :user,
      author_user: users(:arjun),
      user_facing_summary: "Newest visible workflow activity.",
      rationale: nil,
      proposed_reply: {},
      idempotency_key: revision_key,
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action:,
        idempotency_key: revision_key
      ),
      at: Time.current
    )

    first = Conversations::Inbox.call(account: @account).first
    assert_equal owner, first
    assert_not_equal other, first
  end

  test "decoration instantiates only bounded latest messages as history grows" do
    conversation = @account.conversations.create!
    25.times do |index|
      create_message(
        conversation:,
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.zone.local(2026, 7, 20, 10) + index.minutes,
        from_address: "history@example.com"
      )
    end
    instantiated_messages = 0
    subscriber = ActiveSupport::Notifications.subscribe(
      "instantiation.active_record"
    ) do |event|
      if event.payload[:class_name] == "ConversationMessage"
        instantiated_messages += event.payload[:record_count]
      end
    end

    Conversations::Inbox.decorate(
      account: @account,
      conversations: [ conversation ]
    )

    assert_operator instantiated_messages, :<=, 2
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "source-less workflow evidence makes a canonical conversation visible" do
    conversation = Conversation.for_invoice!(invoice: @invoice)
    action = ConversationActions::Proposal.record!(
      conversation:,
      action_type: :other,
      origin_kind: :user,
      created_by_user: users(:arjun),
      user_facing_summary: "Review a source-less collection action.",
      idempotency_key: "source-less-inbox-action"
    )

    conversations = Conversations::Inbox.call(
      account: @account,
      filter: :needs_attention
    ).to_a
    entry = Conversations::Inbox.decorate(
      account: @account,
      conversations:
    ).sole

    assert_equal [ conversation ], conversations
    assert_nil entry.latest_message
    assert_equal action.current_revision.user_facing_summary,
      entry.workflow_summary
    assert_equal action.updated_at, entry.latest_activity_at
  end

  private
    def create_message(
      conversation:,
      direction:,
      kind:,
      status:,
      sent_at: nil,
      received_at: nil,
      invoice: conversation.invoice,
      review_required: false,
      provider_thread_id: nil,
      from_address: nil
    )
      attributes = {
        account: @account,
        invoice:,
        direction:,
        kind:,
        status:,
        sent_at:,
        received_at:,
        provider_thread_id:,
        from_address:,
        review_required:,
        matching_status: review_required ? :unmatched : :matched,
        matching_method: review_required ? :none : :invoice_reference
      }
      if kind.to_s == "manual_email" || review_required
        connection = email_connections(:paid_jar_gmail)
        attributes.merge!(
          email_connection: connection,
          email_connection_generation: connection.credential_generation,
          provider_account_id: connection.provider_account_id
        )
      end

      conversation.conversation_messages.create!(attributes)
    end
end

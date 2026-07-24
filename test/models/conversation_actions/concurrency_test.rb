require "test_helper"
require "timeout"

class ConversationActions::ConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    ids = Thread.new do
      account = Account.create!(
        name: "Action concurrency #{SecureRandom.uuid}"
      )
      actor = account.users.create!(name: "Concurrency actor", role: :owner)
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: SecureRandom.uuid
      )
      customer = source.customers.create!(
        account:,
        external_id: SecureRandom.uuid,
        name: "Concurrency customer",
        email: "action-concurrency@example.com"
      )
      invoice = source.invoices.create!(
        account:,
        customer:,
        external_id: SecureRandom.uuid,
        status: :open,
        amount_due: 100
      )
      conversation = Conversation.for_invoice!(invoice:)
      action = ConversationActions::Proposal.record!(
        conversation:,
        action_type: :answer_due_date,
        origin_kind: :user,
        created_by_user: actor,
        user_facing_summary: "Concurrency proposal.",
        idempotency_key: "concurrency-proposal"
      )
      [ account.id, actor.id, conversation.id, action.id ]
    end.value
    @account_id, @actor_id, @conversation_id, @action_id = ids
  end

  teardown do
    account_id = @account_id
    Thread.new { Account.find_by(id: account_id)&.destroy! }.value if account_id
  end

  test "concurrent edits have one safe current-revision winner" do
    action = ConversationAction.uncached { ConversationAction.find(@action_id) }
    tokens = %w[concurrent-edit-one concurrent-edit-two].to_h do |key|
      [
        key,
        ConversationActions::ActionSnapshot.token_for(
          action:,
          idempotency_key: key
        )
      ]
    end

    results = run_concurrently(tokens.keys) do |key|
      ConversationActions::Revision.record!(
        action: ConversationAction.find(@action_id),
        author_kind: :user,
        author_user: User.find(@actor_id),
        user_facing_summary: "Summary for #{key}.",
        rationale: nil,
        proposed_reply: {},
        idempotency_key: key,
        snapshot_token: tokens.fetch(key)
      )
    end

    assert_equal 1, results.count { |result| result.is_a?(ConversationActionRevision) }
    assert_equal 1, results.count { |result| result.is_a?(ConversationActions::StaleControl) }
    revision_numbers = ConversationAction.uncached do
      ConversationAction.find(@action_id).revisions.order(:revision_number)
        .pluck(:revision_number)
    end
    assert_equal [ 1, 2 ], revision_numbers
  end

  test "concurrent approval and rejection have exactly one terminal winner" do
    action = ConversationAction.uncached { ConversationAction.find(@action_id) }
    revision = action.current_revision
    keys = %w[concurrent-approve concurrent-reject]
    tokens = keys.to_h do |key|
      [
        key,
        ConversationActions::ActionSnapshot.token_for(
          action:,
          idempotency_key: key
        )
      ]
    end

    results = run_concurrently(keys) do |key|
      current_action = ConversationAction.find(@action_id)
      current_revision = ConversationActionRevision.find(revision.id)
      if key == "concurrent-approve"
        ConversationActions::Approval.call(
          action: current_action,
          revision: current_revision,
          actor_user: User.find(@actor_id),
          idempotency_key: key,
          snapshot_token: tokens.fetch(key)
        )
      else
        ConversationActions::Rejection.call(
          action: current_action,
          revision: current_revision,
          actor_user: User.find(@actor_id),
          rationale: "Rejected by the concurrent reviewer.",
          idempotency_key: key,
          snapshot_token: tokens.fetch(key)
        )
      end
    end

    action = ConversationAction.uncached { ConversationAction.find(@action_id) }
    diagnostics = results.map do |result|
      [ result.class.name, result.respond_to?(:message) ? result.message : nil ]
    end
    assert_includes %w[approved rejected], action.status, diagnostics.inspect
    assert_equal 1, results.count { |result| result.is_a?(ConversationAction) }
    assert_equal 1, results.count { |result| result.is_a?(ConversationActions::InvalidTransition) }
    terminal_events = ConversationEvent.uncached do
      ConversationEvent.where(
        conversation_id: @conversation_id,
        kind: %i[conversation_action_approved conversation_action_rejected]
      ).to_a
    end
    assert_equal 1, terminal_events.count
  end

  private
    def run_concurrently(values)
      ready = Queue.new
      start = Queue.new
      threads = values.map do |value|
        Thread.new do
          ready << true
          start.pop
          yield(value)
        rescue StandardError => error
          error
        end
      end
      values.size.times { Timeout.timeout(2) { ready.pop } }
      values.size.times { start << true }
      threads.map { |thread| Timeout.timeout(5) { thread.value } }
    end
end

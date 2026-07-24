require "test_helper"

class WorkflowAmbientAtomicityTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    identifiers = Thread.new { create_records }.value
    @account_id,
      @actor_id,
      @invalid_actor_id,
      @source_id,
      @owner_id,
      @action_id = identifiers
  end

  teardown do
    account_id = @account_id
    invalid_account_id = User.find_by(id: @invalid_actor_id)&.account_id
    Thread.new do
      Account.find_by(id: account_id)&.destroy!
      Account.find_by(id: invalid_account_id)&.destroy!
    end.value
  end

  test "a rescued ambient placement failure rolls back owner reconciliation" do
    initial_event_ids = account.conversation_events.order(:id).pluck(:id)

    Conversation.transaction do
      begin
        CollectionHolds::Placement.call(
          conversation: source,
          conversation_action: action,
          reason: :manual,
          placed_by_kind: :user,
          placed_by_user: invalid_actor,
          idempotency_key: "ambient-invalid-hold"
        )
      rescue ActiveRecord::RecordNotFound
        nil
      end
    end

    assert_equal source, action.reload.conversation
    assert_empty account.collection_holds
    assert_equal initial_event_ids,
      account.conversation_events.order(:id).pluck(:id)
    assert_nil owner.reload.attention_required_at
  end

  test "a rescued ambient opening failure rolls back owner reconciliation" do
    initial_event_ids = account.conversation_events.order(:id).pluck(:id)

    Conversation.transaction do
      begin
        ConversationEscalations::Opening.call(
          conversation: source,
          conversation_action: action,
          category: :ambiguous,
          priority: :high,
          summary: "Do not retain a partial transfer.",
          opened_by_kind: :user,
          opened_by_user: invalid_actor,
          idempotency_key: "ambient-invalid-escalation"
        )
      rescue ActiveRecord::RecordNotFound
        nil
      end
    end

    assert_equal source, action.reload.conversation
    assert_empty account.conversation_escalations
    assert_equal initial_event_ids,
      account.conversation_events.order(:id).pluck(:id)
    assert_nil owner.reload.attention_required_at
  end

  private
    def account
      Account.find(@account_id)
    end

    def invalid_actor
      User.find(@invalid_actor_id)
    end

    def source
      Conversation.find(@source_id)
    end

    def owner
      Conversation.find(@owner_id)
    end

    def action
      ConversationAction.find(@action_id)
    end

    def create_records
      account = Account.create!(name: "Ambient atomicity #{SecureRandom.uuid}")
      actor = account.users.create!(name: "Ambient actor", role: :owner)
      invalid_actor = Account.create!(
        name: "Ambient invalid actor #{SecureRandom.uuid}"
      ).users.create!(name: "Invalid ambient actor", role: :owner)
      connection = account.create_email_connection!(
        provider: :gmail,
        status: :active,
        provider_account_id: "ambient-atomicity-#{SecureRandom.uuid}",
        connected_email: "ambient-atomicity@example.com",
        access_token: "ambient-atomicity-access",
        refresh_token: "ambient-atomicity-refresh",
        token_expires_at: 1.year.from_now,
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
      )
      source_record = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: SecureRandom.uuid
      )
      customer = source_record.customers.create!(
        account:,
        external_id: SecureRandom.uuid,
        name: "Ambient atomicity customer",
        email: "ambient-customer@example.com"
      )
      invoice = source_record.invoices.create!(
        account:,
        customer:,
        external_id: SecureRandom.uuid,
        status: :open,
        amount_due: 100
      )
      source = account.conversations.create!
      source_message = review_message(
        account:,
        connection:,
        conversation: source,
        provider_message_id: "ambient-source"
      )
      action = ConversationActions::Proposal.record!(
        conversation: source,
        source_message:,
        action_type: :other,
        origin_kind: :user,
        created_by_user: actor,
        user_facing_summary: "Move only with a successful mutation.",
        idempotency_key: "ambient-related-action"
      )
      owner = Conversation.for_invoice!(invoice:)
      review_message(
        account:,
        connection:,
        conversation: owner,
        invoice:,
        provider_message_id: "ambient-owner"
      )
      [
        account.id,
        actor.id,
        invalid_actor.id,
        source.id,
        owner.id,
        action.id
      ]
    end

    def review_message(
      account:,
      connection:,
      conversation:,
      provider_message_id:,
      invoice: nil
    )
      conversation.conversation_messages.create!(
        account:,
        invoice:,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id:,
        provider_thread_id: "ambient-atomicity-thread",
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

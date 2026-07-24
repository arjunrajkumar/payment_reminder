class ConversationActions::Proposal
  def self.record!(**attributes)
    new(**attributes).record!
  end

  def initialize(
    conversation:,
    action_type:,
    origin_kind:,
    user_facing_summary:,
    idempotency_key:,
    source_message: nil,
    created_by_user: nil,
    rationale: nil,
    arguments: {},
    proposed_reply: {},
    revision_idempotency_key: nil,
    at: Time.current
  )
    @requested_conversation = conversation
    @account = conversation.account
    @source_message = source_message
    @action_type = action_type.to_s
    @origin_kind = origin_kind.to_s
    @created_by_user = created_by_user
    @user_facing_summary = user_facing_summary
    @rationale = rationale
    @arguments = arguments
    @proposed_reply = proposed_reply
    @idempotency_key = normalize_key(idempotency_key)
    @revision_idempotency_key = normalize_key(
      revision_idempotency_key || idempotency_key
    )
    @at = at
  end

  def record!
    with_current_owner do
      validate_ownership!
      existing = account.conversation_actions.find_by(idempotency_key:)
      next validate_existing!(existing) if existing

      ConversationAction.transaction do
        conversation.with_lock do
          if existing = account.conversation_actions.find_by(idempotency_key:)
            break validate_existing!(existing)
          end

          action = conversation.conversation_actions.create!(
            account:,
            source_message:,
            action_type:,
            status: :pending_approval,
            origin_kind:,
            created_by_user:,
            idempotency_key:,
            validated_work_unit_message_ids: work_unit.message_ids,
            created_at: at,
            updated_at: at
          )
          revision = action.revisions.create!(
            revision_attributes(revision_number: 1)
          )
          ConversationEvent.record!(
            conversation:,
            kind: :conversation_action_created,
            actor_kind: origin_kind,
            actor_user: created_by_user,
            metadata: {
              "conversation_action_id" => action.id,
              "conversation_action_revision_id" => revision.id,
              "revision_number" => revision.revision_number,
              "action_type" => action.action_type,
              "status" => action.status
            },
            created_at: at
          )
          action
        end
      end
    end
  rescue ActiveRecord::RecordNotUnique
    with_current_owner do
      validate_existing!(
        account.conversation_actions.find_by!(idempotency_key:)
      )
    end
  end

  private
    attr_reader :conversation,
      :requested_conversation,
      :account,
      :source_message,
      :action_type,
      :origin_kind,
      :created_by_user,
      :user_facing_summary,
      :rationale,
      :arguments,
      :proposed_reply,
      :idempotency_key,
      :revision_idempotency_key,
      :work_unit,
      :at

    def validate_ownership!
      valid_source = source_message.nil? ||
        (
          source_message.account_id == account.id &&
          work_unit.message_ids.include?(source_message.id)
        )
      valid_actor = if origin_kind == "user"
        created_by_user&.account_id == account.id
      else
        created_by_user.nil?
      end
      raise ActiveRecord::RecordNotFound unless valid_source && valid_actor
    end

    def revision_attributes(revision_number:)
      {
        revision_number:,
        invoice: conversation.invoice,
        customer: conversation.customer,
        author_kind: origin_kind,
        author_user: created_by_user,
        user_facing_summary:,
        rationale:,
        arguments:,
        proposed_reply:,
        idempotency_key: revision_idempotency_key,
        created_at: at,
        updated_at: at
      }
    end

    def validate_existing!(action)
      revision = action.revisions.find_by(revision_number: 1)
      expected_action = {
        source_message_id: source_message&.id,
        action_type:,
        origin_kind:,
        created_by_user_id: created_by_user&.id
      }
      expected_revision = revision_attributes(revision_number: 1).except(
        :invoice,
        :customer,
        :created_at,
        :updated_at
      ).merge(author_user_id: created_by_user&.id).except(:author_user)
      exact = expected_action.all? { |name, value| action.public_send(name) == value } &&
        same_origin_work_unit?(action) &&
        revision.present? &&
        expected_revision.all? do |name, value|
          revision.public_send(name) == value
        end
      return action if exact

      raise ConversationActions::IdempotencyConflict,
        "That action idempotency key was already used."
    end

    def same_origin_work_unit?(action)
      event = account.conversation_events
        .kind_conversation_action_created
        .order(:id)
        .detect { |item| item.metadata["conversation_action_id"] == action.id }
      return false unless event

      origin = account.conversations.find_by(id: event.conversation_id)
      origin && work_unit.conversation_ids.include?(origin.id)
    end

    def with_current_owner
      Conversations::ReviewWorkUnit.with_reconciled_workflow_owner(
        conversation: requested_conversation,
        at:
      ) do |owner, current_work_unit|
        @conversation = owner
        @work_unit = current_work_unit
        yield
      end
    end

    def normalize_key(value)
      value.to_s.strip.presence ||
        raise(ArgumentError, "Idempotency key is required.")
    end
end

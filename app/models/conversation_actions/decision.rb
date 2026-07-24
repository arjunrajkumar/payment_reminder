class ConversationActions::Decision
  def initialize(
    action:,
    revision:,
    actor_user:,
    note:,
    idempotency_key:,
    snapshot_token:,
    status:,
    event_kind:,
    at:
  )
    @action = action
    @revision = revision
    @actor_user = actor_user
    @note = note.to_s.strip.presence
    @idempotency_key = idempotency_key.to_s.strip
    @snapshot_token = snapshot_token
    @status = status.to_s
    @event_kind = event_kind
    @at = at
  end

  def call
    validate_request!
    action.with_lock do
      action.reload
      if action.status != "pending_approval"
        validate_existing_decision!
        next
      end
      payload = ConversationActions::ActionSnapshot.verify!(
        token: snapshot_token,
        action:,
        idempotency_key:
      )
      ConversationActions::ActionSnapshot.ensure_current!(payload:, action:)
      unless revision.id == action.current_revision&.id
        raise ConversationActions::StaleControl,
          ConversationActions::ActionSnapshot::ERROR_MESSAGE
      end

      action.send(
        :record_decision!,
        status:,
        decided_revision: revision,
        decided_by_user: actor_user,
        decided_at: at,
        decision_note: note,
        decision_idempotency_key: idempotency_key
      )
      ConversationEvent.record!(
        conversation: action.conversation,
        kind: event_kind,
        actor_kind: :user,
        actor_user:,
        metadata: {
          "conversation_action_id" => action.id,
          "conversation_action_revision_id" => revision.id,
          "revision_number" => revision.revision_number,
          "action_type" => action.action_type,
          "from_status" => "pending_approval",
          "to_status" => status
        },
        created_at: at
      )
    end
    Conversations::Attention.recompute!(
      conversation: action.conversation,
      actor_user:,
      at:
    )
    action
  end

  private
    attr_reader :action,
      :revision,
      :actor_user,
      :note,
      :idempotency_key,
      :snapshot_token,
      :status,
      :event_kind,
      :at

    def validate_request!
      raise ActiveRecord::RecordNotFound unless
        action.account_id == actor_user&.account_id &&
        revision.conversation_action_id == action.id
      raise ArgumentError, "Idempotency key is required." if idempotency_key.blank?
    end

    def validate_existing_decision!
      exact = action.status == status &&
        action.decided_revision_id == revision.id &&
        action.decided_by_user_id == actor_user.id &&
        action.decision_note == note &&
        action.decision_idempotency_key == idempotency_key
      return if exact

      raise ConversationActions::InvalidTransition,
        "This action has already been decided."
    end
end

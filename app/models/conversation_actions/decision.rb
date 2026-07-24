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
    execution = nil
    action.with_lock do
      action.reload
      if action.status != "pending_approval"
        validate_existing_decision!
        execution = action.execution if status == "approved"
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
      validate_approval! if status == "approved"

      action.send(
        :record_decision!,
        status:,
        decided_revision: revision,
        decided_by_user: actor_user,
        decision_actor_snapshot: actor_snapshot,
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
      execution = create_execution! if status == "approved"
    end
    Conversations::Attention.recompute!(
      conversation: action.conversation,
      actor_user:,
      at:
    )
    action.execution = execution if execution
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

    def create_execution!
      execution = action.create_execution!(
        account: action.account,
        conversation_action_revision: action.decided_revision,
        approved_by_user: actor_user,
        approver_snapshot: {
          **actor_snapshot,
          "approved_at" => at.iso8601(6)
        }
      )
      ConversationEvent.record!(
        conversation: action.conversation,
        kind: :conversation_action_execution_queued,
        actor_kind: :system,
        metadata: {
          "conversation_action_id" => action.id,
          "conversation_action_revision_id" => action.decided_revision_id,
          "conversation_action_execution_id" => execution.id,
          "action_type" => action.action_type
        },
        created_at: at
      )
      execution
    end

    def validate_approval!
      definition = ConversationActions::Catalog.validate!(
        action_type: action.action_type,
        arguments: revision.arguments,
        proposed_reply: revision.proposed_reply
      )
      unless actor_user.active? && actor_user.account_id == action.account_id
        raise ConversationActions::Commands::Unauthorized,
          "The approving user is not active."
      end
      required_role = if definition.action_type == "add_recipient" &&
          definition.arguments.fetch("mode") == "future_reminders"
        :admin
      else
        definition.authorization
      end
      authorized = required_role == :admin ? actor_user.admin? :
        actor_user.role.in?(%w[owner admin member])
      unless authorized
        raise ConversationActions::Commands::Unauthorized,
          "The approving user is not authorized for this command."
      end

      owner = Conversations::ReviewWorkUnit.workflow_owner_for(
        conversation: action.conversation
      )
      if owner.id != action.conversation_id
        raise ConversationActions::StaleControl,
          ConversationActions::ActionSnapshot::ERROR_MESSAGE
      end
      if definition.invoice_required &&
          (
            revision.invoice_id.blank? ||
            revision.invoice&.account_id != action.account_id ||
            revision.customer_id != revision.invoice&.customer_id ||
            owner.invoice_id != revision.invoice_id ||
            owner.customer_id != revision.customer_id
          )
        raise ConversationActions::Catalog::InvalidAction,
          "The proposal invoice context is no longer valid."
      end
      if definition.source_message_required &&
          (
            action.source_message_id.blank? ||
            !Conversations::ReviewWorkUnit.includes_message?(
              conversation: owner,
              message: action.source_message
            )
          )
        raise ConversationActions::Catalog::InvalidAction,
          "The proposal source email is no longer valid."
      end
    end

    def actor_snapshot
      {
        "id" => actor_user.id,
        "name" => actor_user.name,
        "email" => actor_user.identity&.email_address,
        "role" => actor_user.role
      }.compact
    end
end

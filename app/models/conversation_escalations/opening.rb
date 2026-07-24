class ConversationEscalations::Opening
  def self.call(**attributes)
    new(**attributes).call
  end

  def initialize(
    conversation:,
    category:,
    priority:,
    summary:,
    opened_by_kind:,
    idempotency_key:,
    details: nil,
    source_message: nil,
    conversation_action: nil,
    collection_hold: nil,
    opened_by_user: nil,
    at: Time.current
  )
    @requested_conversation = conversation
    @account = conversation.account
    @category = category.to_s
    @priority = priority.to_s
    @summary = summary.to_s.strip
    @details = details.to_s.strip.presence
    @source_message_id = source_message&.id
    @conversation_action_id = conversation_action&.id
    @collection_hold_id = collection_hold&.id
    @opened_by_kind = opened_by_kind.to_s
    @opened_by_user = opened_by_user
    @idempotency_key = idempotency_key.to_s.strip
    @at = at
  end

  def call
    with_current_owner do
      validate_request!
      existing = account.conversation_escalations.find_by(idempotency_key:)
      next validate_existing!(existing) if existing

      conversation.with_lock do
        if existing = account.conversation_escalations.find_by(idempotency_key:)
          break validate_existing!(existing)
        end
        escalation = conversation.conversation_escalations.create!(
          account:,
          invoice: conversation.invoice,
          customer: conversation.customer,
          source_message:,
          conversation_action:,
          collection_hold:,
          category:,
          priority:,
          status: :open,
          summary:,
          details:,
          opened_by_kind:,
          opened_by_user:,
          opened_at: at,
          last_opened_at: at,
          idempotency_key:,
          validated_work_unit_message_ids: work_unit.message_ids
        )
        ConversationEvent.record!(
          conversation:,
          kind: :conversation_escalated,
          actor_kind: opened_by_kind,
          actor_user: opened_by_user,
          metadata: {
            "conversation_escalation_id" => escalation.id,
            "category" => escalation.category,
            "priority" => escalation.priority,
            "status" => escalation.status,
            "invoice_id" => escalation.invoice_id,
            "conversation_action_id" => conversation_action&.id,
            "collection_hold_id" => collection_hold&.id
          }.compact,
          created_at: at
        )
        escalation
      end
    end
  rescue ActiveRecord::RecordNotUnique
    with_current_owner do
      validate_existing!(
        account.conversation_escalations.find_by!(idempotency_key:)
      )
    end
  end

  private
    attr_reader :conversation,
      :requested_conversation,
      :account,
      :category,
      :priority,
      :summary,
      :details,
      :source_message,
      :conversation_action,
      :collection_hold,
      :opened_by_kind,
      :opened_by_user,
      :idempotency_key,
      :work_unit,
      :at

    attr_reader :source_message_id,
      :conversation_action_id,
      :collection_hold_id

    def validate_request!
      valid_actor = if opened_by_kind == "user"
        opened_by_user&.account_id == account.id
      else
        opened_by_user.nil?
      end
      valid_source = source_message.nil? ||
        (
          source_message.account_id == account.id &&
          work_unit.message_ids.include?(source_message.id)
        )
      valid_action = conversation_action.nil? ||
        (
          conversation_action.account_id == account.id &&
          conversation_action.conversation_id == conversation.id
        )
      valid_hold = collection_hold.nil? ||
        (
          collection_hold.account_id == account.id &&
          work_unit.conversation_ids.include?(
            collection_hold.conversation_id
          )
        )
      raise ActiveRecord::RecordNotFound unless
        valid_actor && valid_source && valid_action && valid_hold
      raise ArgumentError, "Idempotency key is required." if idempotency_key.blank?
    end

    def validate_existing!(escalation)
      expected = {
        source_message_id: source_message&.id,
        conversation_action_id: conversation_action&.id,
        collection_hold_id: collection_hold&.id,
        category:,
        priority:,
        summary:,
        details:,
        opened_by_kind:,
        opened_by_user_id: opened_by_user&.id
      }
      exact = same_origin_work_unit?(escalation) &&
        expected.all? do |name, value|
          escalation.public_send(name) == value
        end
      return escalation if exact

      raise ConversationEscalations::IdempotencyConflict,
        "That escalation idempotency key was already used."
    end

    def same_origin_work_unit?(escalation)
      event = account.conversation_events
        .kind_conversation_escalated
        .order(:id)
        .detect do |item|
          item.metadata["conversation_escalation_id"] == escalation.id
        end
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
        reload_related_records!
        yield
      end
    end

    def reload_related_records!
      @source_message = source_message_id &&
        account.conversation_messages.lock.find(source_message_id)
      @conversation_action = conversation_action_id &&
        account.conversation_actions.lock.find(conversation_action_id)
      @collection_hold = collection_hold_id &&
        account.collection_holds.lock.find(collection_hold_id)
    end
end

class CollectionHolds::Placement
  def self.call(**attributes)
    new(**attributes).call
  end

  def initialize(
    conversation:,
    reason:,
    placed_by_kind:,
    idempotency_key:,
    note: nil,
    source_message: nil,
    conversation_action: nil,
    placed_by_user: nil,
    at: Time.current
  )
    @requested_conversation = conversation
    @account = conversation.account
    @reason = reason.to_s
    @note = note.to_s.strip.presence
    @source_message_id = source_message&.id
    @conversation_action_id = conversation_action&.id
    @placed_by_kind = placed_by_kind.to_s
    @placed_by_user = placed_by_user
    @idempotency_key = idempotency_key.to_s.strip
    @at = at
  end

  def call
    with_current_owner do
      validate_request!
      existing = account.collection_holds.find_by(idempotency_key:)
      next validate_existing!(existing) if existing

      invoice.with_lock do
        if existing = account.collection_holds.find_by(idempotency_key:)
          break validate_existing!(existing)
        end
        hold = invoice.collection_holds.create!(
          account:,
          customer: invoice.customer,
          customer_snapshot: customer_snapshot,
          conversation:,
          source_message:,
          conversation_action:,
          reason:,
          status: :active,
          note:,
          placed_by_kind:,
          placed_by_user:,
          placed_at: at,
          in_flight_delivery_message_ids: in_flight_delivery_message_ids,
          idempotency_key:,
          validated_work_unit_message_ids: work_unit.message_ids
        )
        ConversationEvent.record!(
          conversation:,
          kind: :collection_hold_placed,
          actor_kind: placed_by_kind,
          actor_user: placed_by_user,
          metadata: {
            "collection_hold_id" => hold.id,
            "invoice_id" => invoice.id,
            "reason" => hold.reason,
            "status" => hold.status,
            "in_flight_delivery_message_ids" =>
              hold.in_flight_delivery_message_ids,
            "conversation_action_id" => conversation_action&.id
          }.compact,
          created_at: at
        )
        hold
      end
    end
  rescue ActiveRecord::RecordNotUnique
    with_current_owner do
      validate_existing!(account.collection_holds.find_by!(idempotency_key:))
    end
  end

  private
    attr_reader :conversation,
      :requested_conversation,
      :account,
      :invoice,
      :reason,
      :note,
      :source_message,
      :conversation_action,
      :placed_by_kind,
      :placed_by_user,
      :idempotency_key,
      :work_unit,
      :at

    def with_current_owner
      Conversations::ReviewWorkUnit.with_reconciled_workflow_owner(
        conversation: requested_conversation,
        at:
      ) do |owner, current_work_unit|
        @conversation = owner
        @invoice = owner.invoice
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
    end

    attr_reader :source_message_id, :conversation_action_id

    def validate_request!
      raise ArgumentError, "Collection holds require an invoice-backed conversation." unless invoice
      valid_actor = if placed_by_kind == "user"
        placed_by_user&.account_id == account.id
      else
        placed_by_user.nil?
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
      raise ActiveRecord::RecordNotFound unless valid_actor && valid_source && valid_action
      raise ArgumentError, "Idempotency key is required." if idempotency_key.blank?
    end

    def validate_existing!(hold)
      expected = {
        invoice_id: invoice.id,
        conversation_id: conversation.id,
        source_message_id: source_message&.id,
        conversation_action_id: conversation_action&.id,
        reason:,
        note:,
        placed_by_kind:,
        placed_by_user_id: placed_by_user&.id
      }
      return hold if expected.all? { |name, value| hold.public_send(name) == value }

      raise CollectionHolds::IdempotencyConflict,
        "That collection hold idempotency key was already used."
    end

    def in_flight_delivery_message_ids
      invoice.conversation_messages
        .direction_outbound
        .status_pending
        .where.not(provider_delivery_started_at: nil)
        .order(:id)
        .pluck(:id)
    end

    def customer_snapshot
      customer = invoice.customer
      {
        "id" => customer.id,
        "external_id" => customer.external_id,
        "name" => customer.name,
        "email" => customer.email
      }
    end
end

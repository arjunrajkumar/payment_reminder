class ConversationEscalation < ApplicationRecord
  attr_accessor :validated_work_unit_message_ids

  CATEGORIES = {
    dispute: "dispute",
    low_confidence: "low_confidence",
    ambiguous: "ambiguous",
    delivery_failure: "delivery_failure",
    connection_failure: "connection_failure",
    other: "other"
  }.freeze
  PRIORITIES = {
    normal: "normal",
    high: "high",
    urgent: "urgent"
  }.freeze
  STATUSES = {
    open: "open",
    resolved: "resolved"
  }.freeze
  OPENED_BY_KINDS = ConversationAction::ORIGIN_KINDS

  belongs_to :account, inverse_of: :conversation_escalations
  belongs_to :conversation, inverse_of: :conversation_escalations
  belongs_to :invoice, optional: true
  belongs_to :customer, optional: true
  belongs_to :source_message,
    class_name: "ConversationMessage",
    optional: true,
    inverse_of: :conversation_escalations
  belongs_to :conversation_action,
    optional: true,
    inverse_of: :conversation_escalations
  belongs_to :collection_hold,
    optional: true,
    inverse_of: :conversation_escalations
  belongs_to :opened_by_user,
    class_name: "User",
    optional: true,
    inverse_of: :opened_conversation_escalations
  belongs_to :resolved_by_user,
    class_name: "User",
    optional: true,
    inverse_of: :resolved_conversation_escalations

  enum :category, CATEGORIES, prefix: true, validate: true
  enum :priority, PRIORITIES, prefix: true, validate: true
  enum :status, STATUSES, prefix: true, validate: true
  enum :opened_by_kind, OPENED_BY_KINDS, prefix: true, validate: true

  normalizes :idempotency_key,
    :transition_idempotency_key,
    with: ->(value) { value.to_s.strip.presence }

  validates :idempotency_key, presence: true, uniqueness: { scope: :account_id }
  validates :summary, presence: true, length: { maximum: 2_000 }
  validates :details, :resolution_note, length: { maximum: 4_000 }, allow_nil: true
  validates :opened_at, :last_opened_at, presence: true
  validate :records_match_canonical_work_unit
  validate :opening_actor_matches_kind
  validate :resolution_state_matches_status

  before_destroy :prevent_independent_deletion
  before_validation :prevent_unaudited_update, on: :update
  before_update :prevent_unaudited_update

  def resolve!(
    actor_user:,
    resolution_note:,
    idempotency_key:,
    snapshot_token:,
    at: Time.current
  )
    if resolution_note.to_s.strip.blank?
      errors.add(:resolution_note, "is required when resolving an escalation")
      raise ActiveRecord::RecordInvalid, self
    end

    transition!(
      to: :resolved,
      actor_user:,
      note: resolution_note.to_s.strip.presence,
      idempotency_key:,
      snapshot_token:,
      at:
    )
  end

  def reopen!(
    actor_user:,
    idempotency_key:,
    snapshot_token:,
    at: Time.current
  )
    transition!(
      to: :open,
      actor_user:,
      note: nil,
      idempotency_key:,
      snapshot_token:,
      at:
    )
  end

  def resolve_by_system!(reason:, idempotency_key:, at: Time.current)
    key = "system:#{idempotency_key.to_s.strip}"
    with_lock do
      return self if status_resolved? &&
        transition_idempotency_key == key
      return self if status_resolved?

      with_audited_update(:transition) do
        update!(
          status: :resolved,
          resolved_by_user: nil,
          resolved_at: at,
          resolution_note: reason.to_s.first(4_000),
          transition_idempotency_key: key
        )
      end
      clear_linked_execution_attention
      ConversationEvent.record!(
        conversation:,
        kind: :conversation_escalation_resolved,
        actor_kind: :system,
        metadata: {
          "conversation_escalation_id" => id,
          "from_status" => "open",
          "to_status" => "resolved",
          "rationale" => reason.to_s.first(4_000),
          "transition_idempotency_key" => key
        },
        created_at: at
      )
    end
    self
  end

  def transfer_to_conversation!(target, validated_message_ids:)
    previous_message_ids = validated_work_unit_message_ids
    self.validated_work_unit_message_ids = validated_message_ids
    with_audited_update(:conversation_transfer) do
      update!(conversation: target)
    end
  ensure
    self.validated_work_unit_message_ids = previous_message_ids
  end

  def destroy_for_parent!
    @destroying_for_parent = true
    destroy!
  ensure
    @destroying_for_parent = false
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord,
      "Escalations are retained as historical evidence"
  end

  private :transfer_to_conversation!,
    :destroy_for_parent!

  private
    def with_audited_update(kind)
      previous = @audited_update
      @audited_update = kind
      yield
    ensure
      @audited_update = previous
    end

    def prevent_unaudited_update
      changed = changes_to_save.keys.to_set - %w[updated_at lock_version]
      allowed = case @audited_update
      when :transition
        %w[
          status resolved_by_user_id resolved_at resolution_note
          last_opened_at transition_idempotency_key
        ].to_set
      when :conversation_transfer
        %w[conversation_id].to_set
      else
        Set.new
      end
      return if changed.subset?(allowed)

      raise ActiveRecord::ReadOnlyRecord,
        "Escalation provenance and lifecycle are immutable"
    end
    def transition!(to:, actor_user:, note:, idempotency_key:, snapshot_token:, at:)
      key = idempotency_key.to_s.strip
      raise ActiveRecord::RecordNotFound unless actor_user&.account_id == account_id
      raise ArgumentError, "Idempotency key is required." if key.blank?

      if event = transition_event_for(key)
        validate_transition_event!(
          event:,
          to:,
          actor_user:,
          note:
        )
        Conversations::Attention.recompute!(
          conversation:,
          actor_user:,
          at:
        )
        return self
      end

      conversation.with_lock do
        reload
        if status == to.to_s
          validate_exact_transition!(
            to:,
            actor_user:,
            note:,
            idempotency_key: key
          )
          next
        end
        payload = ConversationEscalations::EscalationSnapshot.verify!(
          token: snapshot_token,
          escalation: self,
          idempotency_key: key
        )
        ConversationEscalations::EscalationSnapshot.ensure_current!(
          payload:,
          escalation: self
        )

        from = status
        previous_resolution = {
          "resolved_by_user_id" => resolved_by_user_id,
          "resolved_at" => resolved_at&.iso8601(6),
          "resolution_note" => resolution_note,
          "transition_idempotency_key" => transition_idempotency_key
        }.compact
        attributes = if to == :resolved
          {
            status: :resolved,
            resolved_by_user: actor_user,
            resolved_at: at,
            resolution_note: note,
            transition_idempotency_key: key
          }
        else
          {
            status: :open,
            resolved_by_user: nil,
            resolved_at: nil,
            resolution_note: nil,
            last_opened_at: at,
            transition_idempotency_key: key
          }
        end
        with_audited_update(:transition) { update!(attributes) }
        clear_linked_execution_attention if to == :resolved
        reopen_linked_execution_attention if to == :open
        ConversationEvent.record!(
          conversation:,
          kind: to == :resolved ?
            :conversation_escalation_resolved :
            :conversation_escalation_reopened,
          actor_kind: :user,
          actor_user:,
          metadata: {
            "conversation_escalation_id" => id,
            "category" => category,
            "priority" => priority,
            "from_status" => from,
            "to_status" => to.to_s,
            "rationale" => note,
            "transition_idempotency_key" => key,
            "transitioned_at" => at.iso8601(6),
            "previous_resolution" => previous_resolution.presence
          }.compact,
          created_at: at
        )
      end
      Conversations::Attention.recompute!(
        conversation:,
        actor_user:,
        at:
      )
      self
    end

    def validate_exact_transition!(to:, actor_user:, note:, idempotency_key:)
      event = transition_event_for(idempotency_key)
      return validate_transition_event!(
        event:,
        to:,
        actor_user:,
        note:
      ) if event

      raise ConversationEscalations::InvalidTransition,
        "This escalation has already changed."
    end

    def clear_linked_execution_attention
      linked = ConversationActionExecution.where(effect_escalation_id: id)
        .or(
          ConversationActionExecution.where(delivery_escalation_id: id)
        )
      linked.find_each(&:clear_resolved_attention!)
    end

    def reopen_linked_execution_attention
      linked = ConversationActionExecution.where(effect_escalation_id: id)
        .or(
          ConversationActionExecution.where(delivery_escalation_id: id)
        )
      linked.find_each(&:mark_attention!)
    end

    def transition_event_for(idempotency_key)
      account.conversation_events
        .where(
          kind: %i[
            conversation_escalation_resolved
            conversation_escalation_reopened
          ]
        )
        .order(id: :desc)
        .detect do |event|
          event.metadata["conversation_escalation_id"] == id &&
            event.metadata["transition_idempotency_key"] == idempotency_key
        end
    end

    def validate_transition_event!(event:, to:, actor_user:, note:)
      expected_kind = to == :resolved ?
        "conversation_escalation_resolved" :
        "conversation_escalation_reopened"
      exact = event.kind == expected_kind &&
        event.actor_user_id == actor_user.id &&
        event.metadata["rationale"] == note
      return if exact

      raise ConversationEscalations::InvalidTransition,
        "This escalation transition idempotency key was already used."
    end

    def records_match_canonical_work_unit
      return if account.blank? || conversation.blank?

      errors.add(:conversation, "must be canonical and belong to the escalation account") unless
        conversation.account == account &&
          conversation.canonical_conversation_id.nil?
      errors.add(:invoice, "must belong to the escalation account") if
        invoice.present? && invoice.account != account
      errors.add(:customer, "must belong to the escalation account") if
        customer.present? && customer.account != account
      if new_record? && invoice.present? && customer != invoice.customer
        errors.add(:customer, "must match the escalation invoice")
      end
      if source_message.present? && !(
        source_message.account == account &&
          (
            validated_work_unit_message_ids&.include?(source_message.id) ||
            Conversations::ReviewWorkUnit.includes_message?(
              conversation:,
              message: source_message
            )
          )
      )
        errors.add(:source_message, "must belong to the conversation work unit")
      end
      if conversation_action.present? && !(
        conversation_action.account_id == account.id &&
          conversation_action.conversation_id == conversation.id
      )
        errors.add(:conversation_action, "must belong to the conversation work unit")
      end
      if collection_hold.present? && !(
        collection_hold.account_id == account.id &&
          collection_hold.conversation_id == conversation.id
      )
        errors.add(:collection_hold, "must belong to the conversation work unit")
      end
    end

    def opening_actor_matches_kind
      if opened_by_kind_user?
        errors.add(:opened_by_user, "must be present") if opened_by_user.blank?
      elsif opened_by_user.present?
        errors.add(:opened_by_user, "must be blank for system or AI escalations")
      end
      if opened_by_user.present? && account.present? &&
          opened_by_user.account != account
        errors.add(:opened_by_user, "must belong to the escalation account")
      end
    end

    def resolution_state_matches_status
      if status_open?
        if resolved_by_user.present? || resolved_at.present? || resolution_note.present?
          errors.add(:base, "open escalations cannot have resolution fields")
        end
      elsif resolved_at.blank? ||
          (
            resolved_by_user.blank? &&
            !transition_idempotency_key.to_s.start_with?("system:")
          )
        errors.add(:base, "resolved escalations require an actor and timestamp")
      end
      if resolved_by_user.present? && account.present? &&
          resolved_by_user.account != account
        errors.add(:resolved_by_user, "must belong to the escalation account")
      end
    end

    def prevent_independent_deletion
      return if destroyed_by_association || @destroying_for_parent

      raise ActiveRecord::DeleteRestrictionError,
        "Escalations are retained as historical evidence"
    end
end

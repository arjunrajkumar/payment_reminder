class ConversationAction < ApplicationRecord
  attr_accessor :validated_work_unit_message_ids

  ACTION_TYPES = {
    record_payment_promise: "record_payment_promise",
    answer_due_date: "answer_due_date",
    answer_payment_status: "answer_payment_status",
    answer_outstanding_amount: "answer_outstanding_amount",
    resend_invoice: "resend_invoice",
    add_recipient: "add_recipient",
    open_dispute: "open_dispute",
    other: "other"
  }.freeze
  STATUSES = {
    pending_approval: "pending_approval",
    approved: "approved",
    rejected: "rejected"
  }.freeze
  ORIGIN_KINDS = {
    user: "user",
    system: "system",
    ai: "ai"
  }.freeze

  belongs_to :account, inverse_of: :conversation_actions
  belongs_to :conversation, inverse_of: :conversation_actions
  belongs_to :source_message,
    class_name: "ConversationMessage",
    optional: true,
    inverse_of: :conversation_actions
  belongs_to :created_by_user,
    class_name: "User",
    optional: true,
    inverse_of: :created_conversation_actions
  belongs_to :decided_revision,
    class_name: "ConversationActionRevision",
    optional: true
  belongs_to :decided_by_user,
    class_name: "User",
    optional: true,
    inverse_of: :decided_conversation_actions
  has_many :revisions,
    -> { order(:revision_number) },
    class_name: "ConversationActionRevision",
    dependent: :destroy,
    inverse_of: :conversation_action
  has_many :collection_holds,
    dependent: :nullify,
    inverse_of: :conversation_action
  has_many :conversation_escalations,
    dependent: :nullify,
    inverse_of: :conversation_action

  enum :action_type, ACTION_TYPES, prefix: true, validate: true
  enum :status, STATUSES, prefix: true, validate: true
  enum :origin_kind, ORIGIN_KINDS, prefix: true, validate: true

  normalizes :idempotency_key,
    :decision_idempotency_key,
    with: ->(value) { value.to_s.strip.presence }

  validates :idempotency_key, presence: true, uniqueness: { scope: :account_id }
  validates :decision_note, length: { maximum: 2_000 }, allow_nil: true
  validate :conversation_is_canonical_and_matches_account
  validate :source_message_matches_work_unit
  validate :origin_actor_matches
  validate :decision_state_matches_status
  validate :decision_records_match_action

  before_destroy :prepare_for_parent_destruction
  before_validation :prevent_unaudited_update, on: :update
  before_update :prevent_unaudited_update

  def current_revision
    revisions.max_by(&:revision_number)
  end

  def record_decision!(attributes)
    with_audited_update(:decision) { update!(attributes) }
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

  private :record_decision!,
    :transfer_to_conversation!,
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
      when :decision
        %w[
          status decided_revision_id decided_by_user_id decided_at
          decision_note decision_idempotency_key
        ].to_set
      when :conversation_transfer
        %w[conversation_id].to_set
      else
        Set.new
      end
      return if changed.subset?(allowed)

      raise ActiveRecord::ReadOnlyRecord,
        "Conversation action provenance and lifecycle are immutable"
    end

    def conversation_is_canonical_and_matches_account
      return if conversation.blank? || account.blank?

      errors.add(:conversation, "must belong to the action account") unless
        conversation.account == account
      errors.add(:conversation, "must be canonical") if
        conversation.canonical_conversation_id.present?
    end

    def source_message_matches_work_unit
      return if source_message.blank? || conversation.blank? || account.blank?
      return if source_message.account == account &&
        (
          validated_work_unit_message_ids&.include?(source_message.id) ||
          Conversations::ReviewWorkUnit.includes_message?(
            conversation:,
            message: source_message
          )
        )

      errors.add(:source_message, "must belong to the canonical conversation work unit")
    end

    def origin_actor_matches
      if origin_kind_user?
        errors.add(:created_by_user, "must be present") if created_by_user.blank?
      elsif created_by_user.present?
        errors.add(:created_by_user, "must be blank for system or AI actions")
      end
      if created_by_user.present? && account.present? &&
          created_by_user.account != account
        errors.add(:created_by_user, "must belong to the action account")
      end
    end

    def decision_state_matches_status
      fields = [
        decided_revision,
        decided_by_user,
        decided_at,
        decision_idempotency_key
      ]
      if status_pending_approval?
        errors.add(:base, "pending actions cannot have decision fields") if fields.any?(&:present?)
      elsif fields.any?(&:blank?)
        errors.add(:base, "decided actions require revision, actor, time, and idempotency")
      end
      if status_rejected? && decision_note.blank?
        errors.add(:decision_note, "is required when rejecting an action")
      end
    end

    def decision_records_match_action
      if decided_revision.present? &&
          decided_revision.conversation_action_id != id
        errors.add(:decided_revision, "must belong to this action")
      end
      if decided_by_user.present? && account.present? &&
          decided_by_user.account != account
        errors.add(:decided_by_user, "must belong to the action account")
      end
    end

    def prepare_for_parent_destruction
      unless destroyed_by_association || @destroying_for_parent
        raise ActiveRecord::DeleteRestrictionError,
          "Conversation actions are retained as historical evidence"
      end

      reload
      update_column(:decided_revision_id, nil) if decided_revision_id.present?
    end
end

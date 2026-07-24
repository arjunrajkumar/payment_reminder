class CustomerAiSignal < ApplicationRecord
  include ConversationAi::JsonBounds
  SIGNAL_TYPES = %w[
    positive_response negative_response factual_correction tone_preference
    language_preference salutation_preference concision_preference unclear
  ].index_by(&:itself).freeze
  STATUSES = %w[proposed approved rejected superseded].index_by(&:itself).freeze

  belongs_to :account, inverse_of: :customer_ai_signals
  belongs_to :customer, inverse_of: :customer_ai_signals
  belongs_to :conversation_interpretation,
    inverse_of: :customer_ai_signals
  belongs_to :source_message,
    class_name: "ConversationMessage",
    inverse_of: :source_customer_ai_signals
  belongs_to :target_outbound_message,
    class_name: "ConversationMessage",
    inverse_of: :target_customer_ai_signals
  belongs_to :decided_by_user,
    class_name: "User",
    optional: true,
    inverse_of: :decided_customer_ai_signals
  has_many :guidance_revisions,
    class_name: "CustomerAiGuidanceRevision",
    foreign_key: :source_signal_id,
    dependent: :nullify,
    inverse_of: :source_signal

  enum :signal_type, SIGNAL_TYPES, prefix: true, validate: true
  enum :status, STATUSES, prefix: true, validate: true
  attribute :evidence, default: -> { {} }
  attribute :proposed_guidance, default: -> { {} }
  attribute :decider_snapshot, default: -> { {} }

  validates :confidence_bps, numericality: { in: 0..10_000 }
  validates :idempotency_key,
    presence: true,
    uniqueness: { scope: :conversation_interpretation_id }
  validates :decision_idempotency_key,
    uniqueness: { scope: :account_id },
    allow_nil: true
  validates :decision_note, length: { maximum: 2_000 }, allow_nil: true
  validates_json_bytes :evidence, maximum: 8.kilobytes
  validates_json_bytes :proposed_guidance, maximum: 4.kilobytes
  validates_json_bytes :decider_snapshot, maximum: 4.kilobytes
  validate :records_share_account
  validate :source_and_target_are_anchored

  normalizes :idempotency_key,
    :decision_idempotency_key,
    with: ->(value) { value.to_s.strip.presence }

  def readonly?
    (persisted? && status_in_database != "proposed") || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord,
      "Customer AI signals are retained as historical evidence"
  end

  private
    def records_share_account
      [
        customer,
        conversation_interpretation,
        source_message,
        target_outbound_message,
        decided_by_user
      ].compact.each do |record|
        errors.add(:base, "Signal records must belong to one account") unless
          record.account_id == account_id
      end
    end

    def source_and_target_are_anchored
      return if source_message.blank? || target_outbound_message.blank?

      errors.add(:source_message, "must be inbound") unless
        source_message.direction_inbound?
      errors.add(:target_outbound_message, "must be outbound") unless
        target_outbound_message.direction_outbound?
      errors.add(:target_outbound_message, "must precede the source") unless
        target_outbound_message.occurred_at < source_message.occurred_at
      return if conversation_interpretation.blank?
      return if Conversations::ReviewWorkUnit.includes_message?(
        conversation: conversation_interpretation.conversation,
        message: target_outbound_message
      )

      errors.add(:target_outbound_message, "must be in the same review work unit")
    end
end

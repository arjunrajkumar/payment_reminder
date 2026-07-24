class ConversationInterpretation < ApplicationRecord
  include ConversationAi::JsonBounds
  MAXIMUM_ATTEMPTS = 5
  MAXIMUM_SCHEDULING_ATTEMPTS = 5
  STALE_CLAIM_AFTER = 15.minutes
  STALE_SCHEDULING_AFTER = 10.minutes

  STATUSES = %w[pending running succeeded failed canceled superseded skipped]
    .index_by(&:itself).freeze
  SCHEDULING_STATUSES = %w[
    reserved claimed enqueued consumed exhausted canceled
  ].index_by(&:itself).freeze

  belongs_to :account, inverse_of: :conversation_interpretations
  belongs_to :conversation, inverse_of: :conversation_interpretations
  belongs_to :source_message,
    class_name: "ConversationMessage",
    inverse_of: :conversation_interpretations
  belongs_to :invoice, optional: true
  belongs_to :customer, optional: true
  belongs_to :supersedes_interpretation,
    class_name: "ConversationInterpretation",
    optional: true
  belongs_to :customer_ai_guidance_revision, optional: true
  has_many :superseding_interpretations,
    class_name: "ConversationInterpretation",
    foreign_key: :supersedes_interpretation_id,
    dependent: :nullify
  has_many :conversation_ai_invocations,
    dependent: :destroy,
    inverse_of: :conversation_interpretation
  has_one :conversation_ai_plan,
    dependent: :destroy,
    inverse_of: :conversation_interpretation
  has_many :conversation_ai_evaluations,
    dependent: :destroy,
    inverse_of: :conversation_interpretation
  has_many :customer_ai_signals,
    dependent: :destroy,
    inverse_of: :conversation_interpretation

  enum :status, STATUSES, prefix: true, validate: true
  enum :scheduling_status,
    SCHEDULING_STATUSES,
    prefix: :scheduling,
    validate: true

  attribute :context_snapshot, default: -> { {} }
  attribute :authored_content_warnings, default: -> { [] }
  attribute :source_identity_snapshot, default: -> { {} }
  attribute :reason_codes, default: -> { [] }
  attribute :structured_result, default: -> { {} }

  normalizes :analysis_key,
    :input_digest,
    :scheduling_token,
    :claim_token,
    with: ->(value) { value.to_s.strip.presence }

  validates :analysis_key, uniqueness: { scope: :account_id }
  validates :analysis_key,
    :requested_mode,
    :semantic_prompt_version,
    :provider_adapter_version,
    :result_schema_version,
    :planner_version,
    :catalog_version,
    :provider,
    :requested_model,
    presence: true
  validates :overall_confidence_bps,
    numericality: { in: 0..10_000 },
    allow_nil: true
  validates :summary, length: { maximum: 1_000 }, allow_nil: true
  validates :concise_rationale, length: { maximum: 2_000 }, allow_nil: true
  validates :authored_content_snapshot, length: { maximum: 16_000 }, allow_nil: true
  validates :failure_reason, length: { maximum: 2_000 }, allow_nil: true
  validates_json_bytes :context_snapshot, maximum: 64.kilobytes
  validates_json_bytes :authored_content_warnings, maximum: 4.kilobytes
  validates_json_bytes :source_identity_snapshot, maximum: 16.kilobytes
  validates_json_bytes :reason_codes, maximum: 4.kilobytes
  validates_json_bytes :structured_result, maximum: 64.kilobytes
  validate :records_share_account
  validate :result_fields_match_status

  scope :current, -> { where.not(status: :superseded) }
  scope :due_scheduling, ->(at = Time.current) do
    where(
      status: :pending,
      scheduling_status: :reserved,
      next_retry_at: nil
    )
      .where("next_scheduling_at IS NULL OR next_scheduling_at <= ?", at)
  end
  scope :stale_scheduling, ->(at = Time.current) do
    where(scheduling_status: :claimed)
      .where(scheduling_claimed_at: ...at - STALE_SCHEDULING_AFTER)
  end
  scope :lost_scheduling, -> do
    where(scheduling_status: :enqueued, scheduling_consumed_at: nil)
  end
  scope :stale_claims, ->(at = Time.current) do
    where(status: :running).where(claimed_at: ...at - STALE_CLAIM_AFTER)
  end
  scope :due_retry, ->(at = Time.current) do
    where(status: :pending, scheduling_status: :reserved)
      .where(next_retry_at: ..at)
      .where("next_scheduling_at IS NULL OR next_scheduling_at <= ?", at)
  end
  scope :needs_finalization, -> do
    where(status: %i[succeeded skipped]).where(finalized_at: nil)
  end

  def readonly?
    (persisted? && finalized_at.present?) || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord,
      "Conversation interpretations are retained as historical evidence"
  end

  private
    def records_share_account
      [
        conversation,
        source_message,
        invoice,
        customer,
        customer_ai_guidance_revision
      ].compact.each do |record|
        next if record.account_id == account_id

        errors.add(:base, "AI interpretation records must belong to one account")
      end
      return if source_message.blank? || conversation.blank?
      return if Conversations::ReviewWorkUnit.includes_message?(
        conversation:,
        message: source_message
      )

      errors.add(:source_message, "must belong to the conversation work unit")
    end

    def result_fields_match_status
      if status_succeeded? || status_skipped? || status_superseded?
        errors.add(:input_digest, "must be present") if input_digest.blank?
        errors.add(:message_kind, "must be present") if message_kind.blank?
        errors.add(:requires_human, "must be set") if requires_human.nil?
      elsif [
        accepted_model,
        message_kind,
        language,
        overall_confidence_bps,
        requires_human,
        summary,
        concise_rationale
      ].any?(&:present?) || structured_result.present?
        errors.add(:base, "accepted result fields require a successful or skipped result")
      end
    end
end

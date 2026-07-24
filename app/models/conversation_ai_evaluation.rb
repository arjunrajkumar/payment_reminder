class ConversationAiEvaluation < ApplicationRecord
  include ConversationAi::JsonBounds
  VERDICTS = %w[correct incorrect unsure].index_by(&:itself).freeze

  belongs_to :account, inverse_of: :conversation_ai_evaluations
  belongs_to :conversation_interpretation,
    inverse_of: :conversation_ai_evaluations
  belongs_to :conversation_ai_plan, inverse_of: :conversation_ai_evaluations
  belongs_to :actor_user,
    class_name: "User",
    optional: true,
    inverse_of: :conversation_ai_evaluations
  belongs_to :supersedes_evaluation,
    class_name: "ConversationAiEvaluation",
    optional: true
  has_one :superseding_evaluation,
    class_name: "ConversationAiEvaluation",
    foreign_key: :supersedes_evaluation_id,
    dependent: :nullify

  enum :verdict, VERDICTS, prefix: true, validate: true
  attribute :actor_snapshot, default: -> { {} }
  attribute :corrected_arguments, default: -> { {} }

  normalizes :idempotency_key, with: ->(value) { value.to_s.strip.presence }
  validates :idempotency_key, uniqueness: { scope: :account_id }, presence: true
  validates :note, length: { maximum: 2_000 }, allow_nil: true
  validates_json_bytes :actor_snapshot, maximum: 4.kilobytes
  validates_json_bytes :corrected_arguments, maximum: 8.kilobytes
  validate :records_share_account_and_plan

  scope :latest, -> do
    where.not(id: where.not(supersedes_evaluation_id: nil)
      .select(:supersedes_evaluation_id))
  end

  def readonly?
    persisted? || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord,
      "AI evaluations are append-only"
  end

  private
    def records_share_account_and_plan
      return if account.blank? || conversation_interpretation.blank? ||
        conversation_ai_plan.blank?

      unless conversation_interpretation.account_id == account_id &&
          conversation_ai_plan.account_id == account_id &&
          conversation_ai_plan.conversation_interpretation_id ==
            conversation_interpretation_id
        errors.add(:base, "Evaluation records must refer to one interpretation")
      end
      if actor_user.present? && actor_user.account_id != account_id
        errors.add(:actor_user, "must belong to the evaluation account")
      end
    end
end

class ConversationAiPlan < ApplicationRecord
  include ConversationAi::JsonBounds
  DECISIONS = %w[propose_action human_review no_action].index_by(&:itself).freeze
  STATUSES = %w[current superseded].index_by(&:itself).freeze

  belongs_to :account, inverse_of: :conversation_ai_plans
  belongs_to :conversation_interpretation, inverse_of: :conversation_ai_plan
  has_many :conversation_ai_evaluations,
    dependent: :destroy,
    inverse_of: :conversation_ai_plan

  enum :decision, DECISIONS, prefix: true, validate: true
  enum :status, STATUSES, prefix: true, validate: true

  attribute :arguments, default: -> { {} }
  attribute :proposed_reply, default: -> { {} }
  attribute :planner_reason_codes, default: -> { [] }

  validates :user_facing_summary,
    :planner_version,
    :catalog_version,
    presence: true
  validates :user_facing_summary, length: { maximum: 1_000 }
  validates :confidence_bps,
    numericality: { in: 0..10_000 },
    allow_nil: true
  validates_json_bytes :arguments, maximum: 8.kilobytes
  validates_json_bytes :proposed_reply, maximum: 8.kilobytes
  validates_json_bytes :planner_reason_codes, maximum: 4.kilobytes
  validate :account_matches_interpretation
  validate :proposed_action_is_catalog_valid

  def readonly?
    persisted? || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord,
      "AI plans are retained as historical evidence"
  end

  private
    def account_matches_interpretation
      return if conversation_interpretation.blank? || account.blank?
      return if conversation_interpretation.account_id == account_id

      errors.add(:account, "must match the interpretation account")
    end

    def proposed_action_is_catalog_valid
      if decision_propose_action?
        ConversationActions::Catalog.validate!(
          action_type: proposed_action_type,
          arguments:,
          proposed_reply:
        )
      elsif proposed_action_type.present? || arguments.present?
        errors.add(:proposed_action_type, "must be blank without an action proposal")
      end
    rescue ConversationActions::Catalog::InvalidAction => error
      errors.add(:proposed_action_type, error.message)
    end
end

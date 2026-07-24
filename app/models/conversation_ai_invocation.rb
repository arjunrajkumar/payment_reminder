class ConversationAiInvocation < ApplicationRecord
  include ConversationAi::JsonBounds
  STATUSES = %w[started succeeded failed uncertain superseded]
    .index_by(&:itself).freeze

  belongs_to :account, inverse_of: :conversation_ai_invocations
  belongs_to :conversation_interpretation,
    inverse_of: :conversation_ai_invocations

  enum :status, STATUSES, prefix: true, validate: true

  attribute :sanitized_request, default: -> { {} }
  attribute :sanitized_response, default: -> { {} }
  attribute :provider_metadata, default: -> { {} }

  validates :attempt_number, numericality: { in: 1..5 }
  validates :claim_generation, numericality: { greater_than_or_equal_to: 0 }
  validates :attempt_token,
    :provider,
    :endpoint,
    :api_version,
    :provider_adapter_version,
    :requested_model,
    :application_request_id,
    :started_at,
    presence: true
  validates :attempt_number, uniqueness: { scope: :conversation_interpretation_id }
  validates :application_request_id, uniqueness: true
  validates :failure_message, length: { maximum: 2_000 }, allow_nil: true
  validates_json_bytes :sanitized_request, maximum: 64.kilobytes
  validates_json_bytes :sanitized_response, maximum: 64.kilobytes
  validates_json_bytes :provider_metadata, maximum: 16.kilobytes
  validate :account_matches_interpretation

  def readonly?
    (persisted? && status_in_database != "started") || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord,
      "AI invocation attempts are retained as historical evidence"
  end

  private
    def account_matches_interpretation
      return if conversation_interpretation.blank? || account.blank?
      return if conversation_interpretation.account_id == account_id

      errors.add(:account, "must match the interpretation account")
    end
end

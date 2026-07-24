class CustomerAiGuidanceRevision < ApplicationRecord
  include ConversationAi::JsonBounds
  STATUSES = %w[proposed active rejected superseded].index_by(&:itself).freeze
  AUTHOR_KINDS = %w[user ai].index_by(&:itself).freeze
  ALLOWED_GUIDANCE_KEYS = %w[
    preferred_tone preferred_language preferred_salutation
    preferred_concision communication_notes phrases_to_avoid
  ].freeze
  FORBIDDEN_POLICY_LANGUAGE = /
    mark\s+(?:the\s+)?invoice\s+paid|
    skip\s+reminder|delay\s+reminder|add\s+recipient|ignore\s+(?:policy|cooldown)|
    send\s+automatically|release\s+hold|accept\s+dispute
  /ix

  belongs_to :account, inverse_of: :customer_ai_guidance_revisions
  belongs_to :customer_ai_profile, inverse_of: :guidance_revisions
  belongs_to :source_signal,
    class_name: "CustomerAiSignal",
    optional: true,
    inverse_of: :guidance_revisions
  belongs_to :author_user,
    class_name: "User",
    optional: true,
    inverse_of: :customer_ai_guidance_revisions

  enum :status, STATUSES, prefix: true, validate: true
  enum :author_kind, AUTHOR_KINDS, prefix: true, validate: true
  attribute :author_snapshot, default: -> { {} }
  attribute :structured_guidance, default: -> { {} }
  attribute :evidence_snapshot, default: -> { {} }

  validates :revision_number, numericality: { greater_than: 0 }
  validates :revision_number, uniqueness: { scope: :customer_ai_profile_id }
  validates :idempotency_key,
    presence: true,
    uniqueness: { scope: :customer_ai_profile_id }
  validates :summary, presence: true, length: { maximum: 500 }
  validates_json_bytes :author_snapshot, maximum: 4.kilobytes
  validates_json_bytes :structured_guidance, maximum: 4.kilobytes
  validates_json_bytes :evidence_snapshot, maximum: 16.kilobytes
  validate :records_share_account
  validate :guidance_is_bounded_and_style_only

  def readonly?
    (persisted? && status_in_database != "proposed") || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord,
      "Customer AI guidance revisions are append-only"
  end

  private
    def records_share_account
      return if account.blank? || customer_ai_profile.blank?

      errors.add(:account, "must match the profile account") unless
        customer_ai_profile.account_id == account_id
      if source_signal.present? && source_signal.account_id != account_id
        errors.add(:source_signal, "must belong to the guidance account")
      end
      if author_user.present? && author_user.account_id != account_id
        errors.add(:author_user, "must belong to the guidance account")
      end
    end

    def guidance_is_bounded_and_style_only
      unless structured_guidance.is_a?(Hash) &&
          structured_guidance.keys.all?(String)
        errors.add(:structured_guidance, "must be a JSON object with string keys")
        return
      end
      unknown = structured_guidance.keys - ALLOWED_GUIDANCE_KEYS
      errors.add(:structured_guidance, "contains unsupported policy fields") if
        unknown.any?
      if JSON.generate(structured_guidance).bytesize > 4_000
        errors.add(:structured_guidance, "is too large")
      end
      if JSON.generate(structured_guidance).match?(FORBIDDEN_POLICY_LANGUAGE)
        errors.add(:structured_guidance, "cannot change product or collection policy")
      end
      structured_guidance.each do |key, value|
        valid = if key == "phrases_to_avoid"
          value.is_a?(Array) && value.size <= 10 &&
            value.all? { |item| item.is_a?(String) && item.length <= 100 }
        else
          value.is_a?(String) && value.length <= 500
        end
        errors.add(:structured_guidance, "#{key} is invalid") unless valid
      end
    end
end

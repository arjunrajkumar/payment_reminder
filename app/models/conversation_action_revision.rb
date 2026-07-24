class ConversationActionRevision < ApplicationRecord
  AUTHOR_KINDS = ConversationAction::ORIGIN_KINDS
  MAXIMUM_SUMMARY_LENGTH = 2_000
  MAXIMUM_RATIONALE_LENGTH = 4_000
  MAXIMUM_JSON_BYTES = 64.kilobytes
  MAXIMUM_JSON_DEPTH = 5
  MAXIMUM_JSON_ENTRIES = 100
  MAXIMUM_JSON_STRING_LENGTH = 10_000

  belongs_to :conversation_action,
    touch: true,
    inverse_of: :revisions
  belongs_to :invoice, optional: true
  belongs_to :customer, optional: true
  belongs_to :author_user,
    class_name: "User",
    optional: true,
    inverse_of: :conversation_action_revisions

  enum :author_kind, AUTHOR_KINDS, prefix: true, validate: true

  attribute :arguments, default: -> { {} }
  attribute :proposed_reply, default: -> { {} }

  normalizes :idempotency_key, with: ->(value) { value.to_s.strip.presence }

  validates :revision_number,
    numericality: { only_integer: true, greater_than: 0 },
    uniqueness: { scope: :conversation_action_id }
  validates :idempotency_key,
    presence: true,
    uniqueness: { scope: :conversation_action_id }
  validates :user_facing_summary,
    presence: true,
    length: { maximum: MAXIMUM_SUMMARY_LENGTH }
  validates :rationale,
    length: { maximum: MAXIMUM_RATIONALE_LENGTH },
    allow_nil: true
  validate :context_matches_action_account
  validate :author_matches_kind_and_account
  validate :json_fields_are_bounded_objects

  before_destroy :prevent_independent_deletion

  def readonly?
    (persisted? && !destroyed_by_association) || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord, "Action revisions are append-only"
  end

  private
    def context_matches_action_account
      return if conversation_action.blank?

      account = conversation_action.account
      errors.add(:invoice, "must belong to the action account") if
        invoice.present? && invoice.account != account
      errors.add(:customer, "must belong to the action account") if
        customer.present? && customer.account != account
      if invoice.present? && customer != invoice.customer
        errors.add(:customer, "must match the revision invoice")
      end
    end

    def author_matches_kind_and_account
      if author_kind_user?
        errors.add(:author_user, "must be present") if author_user.blank?
      elsif author_user.present?
        errors.add(:author_user, "must be blank for system or AI revisions")
      end
      if author_user.present? && conversation_action.present? &&
          author_user.account != conversation_action.account
        errors.add(:author_user, "must belong to the action account")
      end
    end

    def json_fields_are_bounded_objects
      validate_json_object(:arguments, arguments)
      validate_json_object(:proposed_reply, proposed_reply)
    end

    def validate_json_object(attribute, value)
      unless value.is_a?(Hash)
        errors.add(attribute, "must be a JSON object")
        return
      end
      if value.to_json.bytesize > MAXIMUM_JSON_BYTES
        errors.add(attribute, "is too large")
      end
      entries = 0
      invalid = false
      walk = lambda do |item, depth|
        invalid = true if depth > MAXIMUM_JSON_DEPTH
        case item
        when Hash
          entries += item.size
          item.each do |key, child|
            invalid = true unless key.is_a?(String)
            walk.call(child, depth + 1)
          end
        when Array
          entries += item.size
          item.each { |child| walk.call(child, depth + 1) }
        when String
          invalid = true if item.length > MAXIMUM_JSON_STRING_LENGTH
        when Numeric, TrueClass, FalseClass, NilClass
          nil
        else
          invalid = true
        end
      end
      walk.call(value, 1)
      invalid = true if entries > MAXIMUM_JSON_ENTRIES
      errors.add(attribute, "contains unsupported or unbounded values") if invalid
    end

    def prevent_independent_deletion
      return if destroyed_by_association

      raise ActiveRecord::DeleteRestrictionError,
        "Action revisions cannot be deleted independently"
    end
end

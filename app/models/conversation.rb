class Conversation < ApplicationRecord
  STATUSES = {
    open: "open",
    resolved: "resolved"
  }.freeze

  belongs_to :account, inverse_of: :conversations
  belongs_to :customer, optional: true, inverse_of: :conversations
  belongs_to :invoice, optional: true, inverse_of: :conversation
  belongs_to :canonical_conversation,
    class_name: "Conversation",
    optional: true,
    inverse_of: :linked_conversations
  has_many :linked_conversations,
    class_name: "Conversation",
    foreign_key: :canonical_conversation_id,
    dependent: :restrict_with_exception,
    inverse_of: :canonical_conversation
  has_many :conversation_messages,
    dependent: :restrict_with_exception,
    inverse_of: :conversation
  has_many :conversation_events,
    dependent: :delete_all,
    inverse_of: :conversation
  has_many :conversation_actions,
    dependent: :destroy,
    inverse_of: :conversation
  has_many :collection_holds,
    dependent: :destroy,
    inverse_of: :conversation
  has_many :conversation_escalations,
    dependent: :destroy,
    inverse_of: :conversation
  has_many :conversation_interpretations,
    dependent: :restrict_with_exception,
    inverse_of: :conversation

  enum :status, STATUSES, prefix: true, validate: true

  validates :invoice_id, uniqueness: true, allow_nil: true
  validate :customer_matches_account
  validate :invoice_matches_account
  validate :customer_matches_invoice
  validate :canonical_conversation_is_a_direct_account_target
  validate :resolved_at_matches_status

  after_create :record_creation_event
  before_destroy :unlink_linked_sources_for_parent_destruction, prepend: true
  before_destroy :prevent_invalid_linked_source_orphaning, prepend: true
  before_destroy :destroy_messages_for_parent_destruction, prepend: true

  class << self
    def for_invoice!(invoice:)
      unless invoice&.persisted?
        raise ArgumentError, "invoice must be persisted"
      end

      find_by(invoice:) || create_or_find_by!(invoice:) do |conversation|
        conversation.account = invoice.account
        conversation.customer = invoice.customer
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
      find_by(invoice:) || raise(error)
    end
  end

  def resolve!(actor_user: nil, at: Time.current)
    transition_to!(
      status: :resolved,
      resolved_at: at,
      event_kind: :conversation_resolved,
      actor_user:,
      at:
    )
  end

  def reopen!(actor_user: nil, at: Time.current)
    transition_to!(
      status: :open,
      resolved_at: nil,
      event_kind: :conversation_reopened,
      actor_user:,
      at:
    )
  end

  def canonical
    canonical_conversation || self
  end

  def conversation_group_ids
    target = canonical
    [ target.id, *target.linked_conversation_ids ]
  end

  def require_attention!(at: Time.current)
    target = canonical
    target.with_lock do
      if target.attention_required_at.nil? || target.attention_required_at < at
        target.update!(attention_required_at: at)
      end
    end
    target
  end

  def clear_attention!(
    actor_user: nil,
    at: Time.current,
    event_kind: :conversation_attention_cleared,
    metadata: {},
    visible_message_ids: nil
  )
    target = canonical
    target.with_lock do
      next if target.attention_required_at.nil?

      event_metadata = metadata
      if actor_user && metadata["outcome"] == "handled"
        unless visible_message_ids
          raise ArgumentError,
            "handled acknowledgement requires visible message IDs"
        end
        event_metadata = metadata.merge(
          "visible_message_ids" => visible_message_ids
        )
      end
      target.update!(attention_required_at: nil)
      target.conversation_events.create!(
        account: target.account,
        kind: event_kind,
        actor_kind: actor_user ? :user : :system,
        actor_user:,
        metadata: event_metadata,
        created_at: at
      )
    end
    target
  end

  def destroy_for_parent!
    @destroying_for_parent = true
    destroy!
  ensure
    @destroying_for_parent = false
  end

  private
    def transition_to!(status:, resolved_at:, event_kind:, actor_user:, at:)
      with_lock do
        next if self.status == status.to_s

        update!(status:, resolved_at:)
        conversation_events.create!(
          account:,
          kind: event_kind,
          actor_kind: actor_user ? :user : :system,
          actor_user:,
          metadata: {},
          created_at: at
        )
      end

      self
    end

    def record_creation_event
      ConversationEvent.record!(
        conversation: self,
        kind: :conversation_created,
        actor_kind: :system
      )
    end

    def customer_matches_account
      return if account.blank? || customer.blank? || customer.account == account

      errors.add(:customer, "must belong to the conversation account")
    end

    def invoice_matches_account
      return if account.blank? || invoice.blank? || invoice.account == account

      errors.add(:invoice, "must belong to the conversation account")
    end

    def customer_matches_invoice
      return if invoice.blank? || customer == invoice.customer

      errors.add(:customer, "must match the conversation invoice customer")
    end

    def canonical_conversation_is_a_direct_account_target
      return if canonical_conversation.blank?

      if canonical_conversation == self
        errors.add(:canonical_conversation, "cannot be the conversation itself")
      end
      if account.present? && canonical_conversation.account != account
        errors.add(:canonical_conversation, "must belong to the conversation account")
      end
      if canonical_conversation.canonical_conversation_id.present?
        errors.add(:canonical_conversation, "must be a direct canonical conversation")
      end
      if invoice.present?
        errors.add(:invoice, "must be blank for a linked source conversation")
      end
    end

    def resolved_at_matches_status
      if status_open? && resolved_at.present?
        errors.add(:resolved_at, "must be blank for an open conversation")
      elsif status_resolved? && resolved_at.blank?
        errors.add(:resolved_at, "must be present for a resolved conversation")
      end
    end

    def prevent_invalid_linked_source_orphaning
      return if destroyed_by_association || @destroying_for_parent

      return unless linked_conversations.exists?

      errors.add(
        :base,
        "cannot be deleted while source conversations remain linked"
      )
      throw :abort
    end

    def destroy_messages_for_parent_destruction
      return unless destroyed_by_association || @destroying_for_parent

      ConversationMessage.destroy_in_dependency_order!(conversation_messages)
      conversation_messages.reset
    end

    def unlink_linked_sources_for_parent_destruction
      return unless destroyed_by_association || @destroying_for_parent

      source_ids = linked_conversation_ids
      return if source_ids.empty?

      account.conversation_messages
        .where(conversation_id: source_ids)
        .where.not(invoice_id: nil)
        .then { |messages| ConversationMessage.destroy_in_dependency_order!(messages) }
      linked_conversations.update_all(canonical_conversation_id: nil)
      linked_conversations.reset
    end
end

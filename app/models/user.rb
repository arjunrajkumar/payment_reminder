class User < ApplicationRecord
  include User::Role

  belongs_to :account
  belongs_to :identity, optional: true
  has_many :notification_subscriptions, dependent: :destroy, inverse_of: :user
  has_many :invoice_reminder_notification_deliveries,
    foreign_key: :recipient_user_id,
    dependent: :nullify,
    inverse_of: :recipient_user
  has_many :conversation_events,
    foreign_key: :actor_user_id,
    dependent: :nullify,
    inverse_of: :actor_user
  has_many :authored_conversation_messages,
    class_name: "ConversationMessage",
    foreign_key: :actor_user_id,
    dependent: :nullify,
    inverse_of: :actor_user
  has_many :reviewed_conversation_messages,
    class_name: "ConversationMessage",
    foreign_key: :reviewed_by_user_id,
    dependent: :nullify,
    inverse_of: :reviewed_by_user
  has_many :created_conversation_actions,
    class_name: "ConversationAction",
    foreign_key: :created_by_user_id,
    dependent: :restrict_with_exception,
    inverse_of: :created_by_user
  has_many :decided_conversation_actions,
    class_name: "ConversationAction",
    foreign_key: :decided_by_user_id,
    dependent: :nullify,
    inverse_of: :decided_by_user
  has_many :approved_conversation_action_executions,
    class_name: "ConversationActionExecution",
    foreign_key: :approved_by_user_id,
    dependent: :nullify,
    inverse_of: :approved_by_user
  has_many :conversation_action_revisions,
    foreign_key: :author_user_id,
    dependent: :restrict_with_exception,
    inverse_of: :author_user
  has_many :placed_collection_holds,
    class_name: "CollectionHold",
    foreign_key: :placed_by_user_id,
    dependent: :restrict_with_exception,
    inverse_of: :placed_by_user
  has_many :released_collection_holds,
    class_name: "CollectionHold",
    foreign_key: :released_by_user_id,
    dependent: :restrict_with_exception,
    inverse_of: :released_by_user
  has_many :opened_conversation_escalations,
    class_name: "ConversationEscalation",
    foreign_key: :opened_by_user_id,
    dependent: :restrict_with_exception,
    inverse_of: :opened_by_user
  has_many :resolved_conversation_escalations,
    class_name: "ConversationEscalation",
    foreign_key: :resolved_by_user_id,
    dependent: :restrict_with_exception,
    inverse_of: :resolved_by_user

  before_destroy :reset_workflow_evidence_associations, prepend: true

  validates :name, presence: true

  def deactivate
    transaction do
      update! active: false, identity: nil
    end
  end

  private
    def reset_workflow_evidence_associations
      %i[
        created_conversation_actions
        decided_conversation_actions
        approved_conversation_action_executions
        conversation_action_revisions
        placed_collection_holds
        released_collection_holds
        opened_conversation_escalations
        resolved_conversation_escalations
      ].each { |name| association(name).reset }
    end
end

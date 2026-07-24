class Account < ApplicationRecord
  has_many :invoice_sources, dependent: :destroy
  has_many :stripe_installation_claims,
    class_name: "InvoiceSources::Stripe::InstallationClaim",
    dependent: :nullify
  has_one :email_connection, dependent: :destroy, inverse_of: :account
  has_many :customers, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :payment_promises, dependent: :destroy, inverse_of: :account
  has_many :invoice_reminders, dependent: :destroy, inverse_of: :account
  has_many :invoice_reminder_notification_deliveries,
    dependent: :destroy,
    inverse_of: :account
  has_many :invoice_reminder_suppressions,
    dependent: :destroy,
    inverse_of: :account
  has_many :conversation_actions, dependent: :destroy, inverse_of: :account
  has_many :conversation_action_executions,
    dependent: :destroy,
    inverse_of: :account
  has_many :collection_holds, dependent: :destroy, inverse_of: :account
  has_many :conversation_escalations, dependent: :destroy, inverse_of: :account
  before_destroy :destroy_workflows_before_users, prepend: true
  before_destroy :destroy_conversation_messages_in_dependency_order
  has_many :conversation_messages, dependent: :destroy, inverse_of: :account
  has_many :conversations, dependent: :destroy, inverse_of: :account
  has_many :conversation_events, dependent: :delete_all, inverse_of: :account
  has_many :email_message_receipts, dependent: :destroy, inverse_of: :account
  has_many :users, dependent: :destroy
  has_many :customer_segments, dependent: :destroy, inverse_of: :account
  has_many :platform_admin_events, dependent: :nullify, inverse_of: :account

  include CustomerSegments, InvoiceSchedules, Remindable

  before_validation :assign_external_account_id, on: :create

  validates :external_account_id, :name, presence: true
  validates :invoice_reminder_from_email,
    format: { with: URI::MailTo::EMAIL_REGEXP },
    allow_blank: true
  validates :invoice_reminder_from_email, length: { maximum: 254 }
  validates :invoice_reminder_from_email,
    presence: true,
    if: :automatic_invoice_reminders_enabled?
  validates :invoice_reminder_from_name, length: { maximum: 100 }, allow_blank: true
  validate :active_email_connection_required, if: :automatic_invoice_reminders_enabled?
  validate :sender_address_matches_email_connection, if: :automatic_invoice_reminders_enabled?
  normalizes :invoice_reminder_from_email,
    with: ->(value) { value.strip.downcase.presence }

  class << self
    def create_with_owner(account:, owner:)
      transaction do
        create!(**account).tap do |account|
          account.users.create!(role: :system, name: "System")
          account.users.create!(**owner.with_defaults(role: :owner, verified_at: Time.current))
        end
      end
    end
  end

  def slug
    "/#{AccountSlug.encode(external_account_id)}"
  end

  def active?
    true
  end

  def email_ready?
    email_connection&.gmail_ready? &&
      email_connection.sender_matches?(invoice_reminder_from_email)
  end

  private
    def destroy_workflows_before_users
      ConversationActionExecution.where(account_id: id).find_each do |execution|
        execution.send(:destroy_for_parent!)
      end
      ConversationAction.where(account_id: id).find_each do |action|
        action.send(:destroy_for_parent!)
      end
      CollectionHold.where(account_id: id).find_each do |hold|
        hold.send(:destroy_for_parent!)
      end
      ConversationEscalation.where(account_id: id).find_each do |escalation|
        escalation.send(:destroy_for_parent!)
      end
      %i[
        conversation_action_executions
        conversation_actions
        collection_holds
        conversation_escalations
      ].each { |name| association(name).reset }
    end

    def destroy_conversation_messages_in_dependency_order
      ConversationMessage.destroy_in_dependency_order!(conversation_messages)
    end

    def assign_external_account_id
      self.external_account_id ||= ExternalIdSequence.next
    end
    def active_email_connection_required
      return if email_ready?

      errors.add(:automatic_invoice_reminders_enabled, "requires an active Gmail connection")
    end

    def sender_address_matches_email_connection
      return if email_connection.blank? || invoice_reminder_from_email.blank?
      return if email_connection.sender_matches?(invoice_reminder_from_email)

      errors.add(:invoice_reminder_from_email, "must match the connected Gmail account")
    end
end

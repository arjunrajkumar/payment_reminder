class Account < ApplicationRecord
  has_many :invoice_sources, dependent: :destroy
  has_one :outbound_email_connection, dependent: :destroy, inverse_of: :account
  has_many :customers, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :invoice_reminders, dependent: :destroy, inverse_of: :account
  has_many :users, dependent: :destroy
  has_many :customer_segments, dependent: :destroy, inverse_of: :account

  include CustomerSegments, InvoiceSchedules, Remindable

  before_create :assign_external_account_id

  validates :name, presence: true
  validates :invoice_reminder_from_email,
    format: { with: URI::MailTo::EMAIL_REGEXP },
    allow_blank: true
  validates :invoice_reminder_from_email, length: { maximum: 254 }
  validates :invoice_reminder_from_email,
    presence: true,
    if: :automatic_invoice_reminders_enabled?
  validates :invoice_reminder_from_name, length: { maximum: 100 }, allow_blank: true
  validate :active_outbound_email_connection_required, if: :automatic_invoice_reminders_enabled?
  validate :sender_address_matches_outbound_connection, if: :automatic_invoice_reminders_enabled?
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

  def outbound_email_ready?
    outbound_email_connection&.active? &&
      outbound_email_connection.sender_matches?(invoice_reminder_from_email)
  end

  private
    def assign_external_account_id
      self.external_account_id ||= ExternalIdSequence.next
    end
    def active_outbound_email_connection_required
      return if outbound_email_ready?

      errors.add(:automatic_invoice_reminders_enabled, "requires an active Gmail connection")
    end

    def sender_address_matches_outbound_connection
      return if outbound_email_connection.blank? || invoice_reminder_from_email.blank?
      return if outbound_email_connection.sender_matches?(invoice_reminder_from_email)

      errors.add(:invoice_reminder_from_email, "must match the connected Gmail account")
    end
end

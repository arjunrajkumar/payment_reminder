class Customer < ApplicationRecord
  include Segmentation
  include ProviderSync

  belongs_to :account, inverse_of: :customers
  belongs_to :invoice_source, inverse_of: :customers
  belongs_to :customer_segment, inverse_of: :customers
  has_many :invoices, dependent: :destroy, inverse_of: :customer
  has_many :conversations, dependent: :nullify, inverse_of: :customer
  has_many :additional_email_addresses,
    -> { order(:id) },
    class_name: "CustomerEmailAddress",
    dependent: :destroy,
    inverse_of: :customer

  before_validation :assign_initial_customer_segment, on: :create
  before_destroy :release_optional_workflow_snapshots, prepend: true

  validates :external_id, :name, presence: true
  validates :external_id, uniqueness: { scope: :invoice_source_id }
  validate :invoice_source_matches_account
  validate :customer_segment_matches_account

  delegate :payer_segment, to: :customer_segment

  def reminder_email_addresses
    [ synced_reminder_email_address, *additional_email_addresses.pluck(:email) ]
      .filter_map { |email_address| normalize_reminder_email_address(email_address) }
      .uniq
  end

  def synced_reminder_email_address
    normalize_reminder_email_address(email)
  end

  private
    def release_optional_workflow_snapshots
      ConversationActionRevision.where(customer_id: id)
        .update_all(customer_id: nil)
      CollectionHold.where(customer_id: id)
        .update_all(customer_id: nil)
      ConversationEscalation.where(customer_id: id)
        .update_all(customer_id: nil)
    end

    def assign_initial_customer_segment
      self.customer_segment ||= account&.customer_segment(:normal_debtor)
    end

    def customer_segment_matches_account
      return if account.blank? || customer_segment.blank? || customer_segment.account == account

      errors.add(:customer_segment, "must belong to the customer account")
    end

    def invoice_source_matches_account
      return if account.blank? || invoice_source.blank? || invoice_source.account == account

      errors.add(:invoice_source, "must belong to the customer account")
    end

    def normalize_reminder_email_address(email_address)
      normalized_email_address = email_address.to_s.strip.downcase
      return if normalized_email_address.blank?
      return if normalized_email_address.length > 254
      return unless normalized_email_address.match?(URI::MailTo::EMAIL_REGEXP)

      normalized_email_address
    end
end

class Customer < ApplicationRecord
  include Segmentation
  include ProviderSync

  belongs_to :account, inverse_of: :customers
  belongs_to :invoice_source, inverse_of: :customers
  belongs_to :customer_segment, inverse_of: :customers
  has_many :invoices, dependent: :destroy, inverse_of: :customer

  before_validation :assign_initial_customer_segment, on: :create

  validates :external_id, :name, presence: true
  validates :external_id, uniqueness: { scope: :invoice_source_id }
  validate :customer_segment_matches_account

  delegate :payer_segment, to: :customer_segment

  private
    def assign_initial_customer_segment
      self.customer_segment ||= account&.customer_segment(:normal_debtor)
    end

    def customer_segment_matches_account
      return if account.blank? || customer_segment.blank? || customer_segment.account == account

      errors.add(:customer_segment, "must belong to the customer account")
    end
end

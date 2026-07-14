class Customer < ApplicationRecord
  include Invoicing, PaymentHistory, ProviderSync

  belongs_to :account, inverse_of: :customers
  belongs_to :invoice_source, inverse_of: :customers
  has_many :invoices, dependent: :destroy, inverse_of: :customer

  validates :external_id, :name, presence: true
  validates :external_id, uniqueness: { scope: :invoice_source_id }
end

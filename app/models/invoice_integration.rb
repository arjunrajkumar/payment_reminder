class InvoiceIntegration < ApplicationRecord
  belongs_to :account, inverse_of: :invoice_integrations

  enum :provider, {
    xero: "xero",
    stripe: "stripe",
    quickbooks: "quickbooks",
    zoho_books: "zoho_books"
  }

  enum :status, {
    pending: "pending",
    active: "active",
    disconnected: "disconnected",
    error: "error"
  }

  validates :provider, :status, presence: true
  validates :external_account_id, presence: true
  validates :external_account_id, uniqueness: { scope: [ :account_id, :provider ] }
end

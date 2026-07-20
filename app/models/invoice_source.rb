class InvoiceSource < ApplicationRecord
  SENSITIVE_TOKEN_KEYS = %w[access_token refresh_token id_token client_secret].freeze

  AvailableSource = Struct.new(
    :provider,
    :name,
    :connect_path_name,
    :connected_source,
    keyword_init: true
  )

  AVAILABLE_SOURCES = [
    {
      provider: :xero,
      name: "Xero",
      connect_path_name: :new_xero_connection_path
    },
    {
      provider: :stripe,
      name: "Stripe",
      connect_path_name: :new_stripe_connection_path
    }
  ].freeze

  belongs_to :account, inverse_of: :invoice_sources
  has_many :customers, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :webhook_events, class_name: "InvoiceSources::Webhooks::Event", dependent: :destroy

  attribute :scopes, default: -> { [] }
  attribute :provider_data, default: -> { {} }
  attribute :raw_token_data, default: -> { {} }

  encrypts :access_token, :refresh_token

  enum :provider, {
    xero: "xero",
    stripe: "stripe"
  }

  enum :status, {
    pending: "pending",
    active: "active",
    disconnected: "disconnected",
    error: "error"
  }

  validates :provider, :status, presence: true
  validates :external_account_id, presence: true
  validates :provider, uniqueness: { scope: :account_id }
  validates :external_account_id, uniqueness: { scope: :provider }

  def self.available_sources_for(account)
    AVAILABLE_SOURCES.map do |source|
      AvailableSource.new(
        **source,
        connected_source: connected_for_provider(account, source.fetch(:provider))
      )
    end
  end

  def self.connected_for(account)
    account.invoice_sources.order(:provider).select(&:connected?)
  end

  def self.connected_for_provider(account, provider)
    account.invoice_sources.public_send(provider).detect(&:connected?)
  end

  def self.sanitized_token_data(token_data)
    token_data.to_h.stringify_keys.except(*SENSITIVE_TOKEN_KEYS)
  end

  def connect!(...)
    provider_adapter.connect!(...)
  end

  def sync_invoices!
    provider_adapter.sync_invoices!
    customers.find_each(&:refresh_customer_segment!)
  end

  def sync_invoice!(external_id:)
    previous_customer = invoices.find_by(external_id: external_id)&.customer
    provider_adapter.sync_invoice!(external_id: external_id)
    invoice = invoices.find_by(external_id: external_id)

    [ previous_customer, invoice&.customer ].compact.uniq.each(&:refresh_customer_segment!)
    invoice
  end

  def connected?
    provider_adapter.connected?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def disconnect!
    update!(
      status: :disconnected,
      access_token: nil,
      refresh_token: nil,
      expires_at: nil,
      raw_token_data: {}
    )
  end

  private
    def provider_adapter
      provider_class.new(self)
    end

    def provider_class
      "InvoiceSources::#{provider.classify}".constantize
    end
end

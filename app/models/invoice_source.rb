class InvoiceSource < ApplicationRecord
  AvailableSource = Struct.new(
    :provider,
    :name,
    :description,
    :connect_path_name,
    :connected_source,
    keyword_init: true
  )

  AVAILABLE_SOURCES = [
    {
      provider: :xero,
      name: "Xero",
      description: "Read invoices and customer details from your Xero organisation.",
      connect_path_name: :new_xero_connection_path
    },
    {
      provider: :stripe,
      name: "Stripe",
      description: "Read invoices and customer details from your connected Stripe account.",
      connect_path_name: :new_stripe_connection_path
    }
  ].freeze

  belongs_to :account, inverse_of: :invoice_sources
  has_many :invoices, dependent: :destroy
  has_many :webhook_events, class_name: "InvoiceSources::Webhooks::Event", dependent: :destroy

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

  def connect!(...)
    provider_adapter.connect!(...)
  end

  def sync_invoices!
    provider_adapter.sync_invoices!
  end

  def sync_invoice!(...)
    provider_adapter.sync_invoice!(...)
  end

  def connected?
    provider_adapter.connected?
  end

  def requires_reauthorization?
    provider_adapter.requires_reauthorization?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def disconnect!
    update!(
      status: :disconnected,
      access_token: nil,
      refresh_token: nil,
      expires_at: nil
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

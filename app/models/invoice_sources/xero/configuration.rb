require "cgi"

module InvoiceSources
  class Xero
    class Configuration
      DEFAULT_HOST = "http://localhost:3000"

      DEFAULT_SCOPES = %w[
        openid
        profile
        email
        accounting.invoices.read
        accounting.contacts.read
        offline_access
      ].freeze

      IDENTITY_SCOPES = %w[
        openid
        profile
        email
      ].freeze

      def initialize(host: ENV["HOST"])
        @host = host.presence || DEFAULT_HOST
      end

      def configured?
        client_id.present? && client_secret.present?
      end

      def client_id
        credentials[:client_id]
      end

      def client_secret
        credentials[:client_secret]
      end

      def webhook_signing_key
        credentials[:webhook_signing_key]
      end

      def scopes
        DEFAULT_SCOPES.join(" ")
      end

      def identity_scopes
        IDENTITY_SCOPES.join(" ")
      end

      def redirect_uri
        "#{host.chomp("/")}/xero/callback"
      end

      def signup_redirect_uri
        "#{host.chomp("/")}/signup/xero/callback"
      end

      def session_redirect_uri
        "#{host.chomp("/")}/session/xero/callback"
      end

      def authorization_uri
        URI("https://login.xero.com/identity/connect/authorize")
      end

      def token_uri
        URI("https://identity.xero.com/connect/token")
      end

      def issuer
        "https://identity.xero.com"
      end

      def resources_audience
        "https://identity.xero.com/resources"
      end

      def jwks_uri
        URI("https://identity.xero.com/.well-known/openid-configuration/jwks")
      end

      def connections_uri
        URI("https://api.xero.com/connections")
      end

      def userinfo_uri
        URI("https://api.xero.com/identity/connect/userinfo")
      end

      def invoices_uri
        URI("https://api.xero.com/api.xro/2.0/Invoices")
      end

      def invoice_uri(invoice_id)
        URI("https://api.xero.com/api.xro/2.0/Invoices/#{CGI.escape(invoice_id)}")
      end

      def online_invoice_uri(invoice_id)
        URI("#{invoice_uri(invoice_id)}/OnlineInvoice")
      end

      private
        attr_reader :host

        def credentials
          Rails.application.credentials.xero || {}
        end
    end
  end
end

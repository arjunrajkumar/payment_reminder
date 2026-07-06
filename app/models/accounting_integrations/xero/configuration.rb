module AccountingIntegrations
  class Xero
    class Configuration
      DEFAULT_SCOPES = %w[
        openid
        profile
        email
        accounting.invoices.read
        accounting.contacts.read
        offline_access
      ].freeze

      def configured?
        client_id.present? && client_secret.present? && redirect_uri.present?
      end

      def client_id
        credentials[:client_id]
      end

      def client_secret
        credentials[:client_secret]
      end

      def scopes
        credentials[:scopes].presence || DEFAULT_SCOPES.join(" ")
      end

      def redirect_uri
        credentials[:redirect_uri]
      end

      def authorization_uri
        URI("https://login.xero.com/identity/connect/authorize")
      end

      def token_uri
        URI("https://identity.xero.com/connect/token")
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

      private
        def credentials
          Rails.application.credentials.xero || {}
        end
    end
  end
end

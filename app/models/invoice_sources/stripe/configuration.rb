module InvoiceSources
  class Stripe
    class Configuration
      DEFAULT_SCOPE = "read_write"

      def configured?
        client_id.present? && secret_key.present? && redirect_uri.present?
      end

      def client_id
        credentials[:client_id]
      end

      def secret_key
        credentials[:secret_key]
      end

      def scope
        DEFAULT_SCOPE
      end

      def redirect_uri
        credentials[:redirect_uri]
      end

      def authorization_uri
        URI("https://connect.stripe.com/oauth/authorize")
      end

      def token_uri
        URI("https://connect.stripe.com/oauth/token")
      end

      def invoices_uri
        URI("https://api.stripe.com/v1/invoices")
      end

      private
        def credentials
          Rails.application.credentials.stripe || {}
        end
    end
  end
end

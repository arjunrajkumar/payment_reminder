module InvoiceSources
  class Xero
    attr_reader :source

    def initialize(source)
      @source = source
    end

    def connect!(code:)
      token_set = oauth_client.exchange_code(code: code)
      connections = oauth_client.connections(access_token: token_set.fetch("access_token"))
      userinfo = oauth_client.userinfo(access_token: token_set.fetch("access_token"))
      primary_connection = connections.first || {}
      tenant_id = primary_connection.fetch("tenantId")

      source.update!(
        provider: :xero,
        status: :active,
        external_account_id: tenant_id,
        external_account_name: primary_connection["tenantName"],
        access_token: token_set.fetch("access_token"),
        refresh_token: token_set.fetch("refresh_token"),
        expires_at: Time.current + token_set.fetch("expires_in").to_i.seconds,
        scopes: token_set["scope"].to_s.split,
        provider_data: {
          xero_user_id: userinfo["xero_userid"] || userinfo["sub"],
          email: userinfo["email"],
          token_type: token_set.fetch("token_type", "Bearer"),
          connections: connections
        },
        raw_token_data: InvoiceSource.sanitized_token_data(token_set),
        last_error: nil
      )

      source
    end

    def sync_invoices!
      ensure_access_token!
      InvoiceSync.new(source, client: oauth_client).sync!
    end

    def sync_invoice!(external_id:)
      ensure_access_token!
      InvoiceSync.new(source, client: oauth_client).sync_invoice_by_id!(external_id)
    end

    def connected?
      source.active? && source.external_account_id.present? && source.refresh_token.present?
    end

    def refresh_access_token!
      token_set = oauth_client.refresh_token(refresh_token: source.refresh_token)

      source.update!(
        access_token: token_set.fetch("access_token"),
        refresh_token: token_set.fetch("refresh_token"),
        expires_at: Time.current + token_set.fetch("expires_in").to_i.seconds,
        scopes: token_set["scope"].present? ? token_set["scope"].to_s.split : source.scopes,
        raw_token_data: InvoiceSource.sanitized_token_data(token_set),
        status: :active,
        last_error: nil
      )
    end

    private
      def ensure_access_token!
        refresh_access_token! if source.expired?
      end

      def oauth_client
        @oauth_client ||= OauthClient.new
      end
  end
end

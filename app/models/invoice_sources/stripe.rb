module InvoiceSources
  class Stripe
    attr_reader :source

    def initialize(source)
      @source = source
    end

    def connect!(code:)
      token_set = oauth_client.exchange_code(code: code)
      stripe_account_id = token_set.fetch("stripe_user_id")

      source.update!(
        provider: :stripe,
        status: :active,
        external_account_id: stripe_account_id,
        external_account_name: stripe_account_id,
        access_token: token_set["access_token"],
        refresh_token: token_set["refresh_token"],
        expires_at: nil,
        scopes: token_set["scope"].to_s.split,
        provider_data: {
          livemode: token_set["livemode"],
          token_type: token_set["token_type"],
          stripe_publishable_key: token_set["stripe_publishable_key"]
        }.compact,
        raw_token_data: InvoiceSource.sanitized_token_data(token_set),
        last_error: nil
      )

      source
    end

    def sync_invoices!
      InvoiceSync.new(source, client: oauth_client).sync!
    end

    def sync_invoice!(external_id:)
      InvoiceSync.new(source, client: oauth_client).sync_invoice_by_id!(external_id)
    end

    def connected?
      source.active? && source.external_account_id.present?
    end

    private
      def oauth_client
        @oauth_client ||= OauthClient.new
      end
  end
end

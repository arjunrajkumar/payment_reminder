require "test_helper"

module InvoiceSources
  class Stripe
    class OauthClientTest < ActiveSupport::TestCase
      test "authorization_url includes Stripe OAuth parameters" do
        with_stripe_credentials(
          client_id: "ca_123",
          secret_key: "sk_test_123"
        ) do
          config = Configuration.new

          url = OauthClient.new(config: config).authorization_url(
            redirect_uri: "https://example.com/stripe/callback",
            state: "state-123"
          )

          uri = URI(url)
          params = Rack::Utils.parse_query(uri.query)

          assert_equal "connect.stripe.com", uri.host
          assert_equal "/oauth/authorize", uri.path
          assert_equal "code", params["response_type"]
          assert_equal "ca_123", params["client_id"]
          assert_equal "https://example.com/stripe/callback", params["redirect_uri"]
          assert_equal "read_write", params["scope"]
          assert_equal "state-123", params["state"]
        end
      end

      test "invoices reads every Stripe pagination page for the connected account" do
        with_stripe_credentials(secret_key: "sk_test_123") do
          stub_request(:get, "https://api.stripe.com/v1/invoices?limit=100")
            .with(headers: { "Stripe-Account" => "acct_123" })
            .to_return(
              status: 200,
              body: {
                data: [ { id: "in_1" } ],
                has_more: true
              }.to_json
            )

          stub_request(:get, "https://api.stripe.com/v1/invoices?limit=100&starting_after=in_1")
            .with(headers: { "Stripe-Account" => "acct_123" })
            .to_return(
              status: 200,
              body: {
                data: [ { id: "in_2" } ],
                has_more: false
              }.to_json
            )

          payload = OauthClient.new.invoices(stripe_account_id: "acct_123")

          assert_equal [ "in_1", "in_2" ], payload.fetch("data").pluck("id")
        end
      end

      private
        def with_stripe_credentials(**stripe)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.stripe = stripe
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end

require "test_helper"

module InvoiceSources
  class Xero
    class OauthClientTest < ActiveSupport::TestCase
      test "authorization_url includes Xero OAuth parameters" do
        with_xero_credentials(
          client_id: "client-123",
          client_secret: "secret-123"
        ) do
          config = Configuration.new

          url = OauthClient.new(config: config).authorization_url(
            redirect_uri: "https://example.com/xero/callback",
            state: "state-123"
          )

          uri = URI(url)
          params = Rack::Utils.parse_query(uri.query)

          assert_equal "login.xero.com", uri.host
          assert_equal "/identity/connect/authorize", uri.path
          assert_equal "code", params["response_type"]
          assert_equal "client-123", params["client_id"]
          assert_equal "https://example.com/xero/callback", params["redirect_uri"]
          assert_equal Configuration::DEFAULT_SCOPES.join(" "), params["scope"]
          assert_equal "state-123", params["state"]
        end
      end

      test "invoices passes the requested Xero filter" do
        stub_request(
          :get,
          "https://api.xero.com/api.xro/2.0/Invoices?where=Type%3D%3D%22ACCREC%22"
        ).with(
          headers: {
            "Authorization" => "Bearer access-token",
            "xero-tenant-id" => "tenant-123"
          }
        ).to_return(
          status: 200,
          body: { Invoices: [] }.to_json
        )

        payload = OauthClient.new.invoices(
          access_token: "access-token",
          tenant_id: "tenant-123",
          where: 'Type=="ACCREC"'
        )

        assert_equal [], payload.fetch("Invoices")
      end

      private
        def with_xero_credentials(**xero)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.xero = xero
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end

require "test_helper"

module AccountingIntegrations
  class Xero
    class OauthClientTest < ActiveSupport::TestCase
      test "authorization_url includes Xero OAuth parameters" do
        with_xero_credentials(
          client_id: "client-123",
          client_secret: "secret-123",
          scopes: "openid profile offline_access"
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
          assert_equal "openid profile offline_access", params["scope"]
          assert_equal "state-123", params["state"]
        end
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

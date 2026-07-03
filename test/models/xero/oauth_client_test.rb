require "test_helper"

module Xero
  class OauthClientTest < ActiveSupport::TestCase
    test "authorization_url includes Xero OAuth parameters" do
      config = Configuration.new(
        env: {
          "XERO_CLIENT_ID" => "client-123",
          "XERO_CLIENT_SECRET" => "secret-123",
          "XERO_SCOPES" => "openid profile offline_access"
        }
      )

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
end

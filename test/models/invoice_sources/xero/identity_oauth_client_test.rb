require "test_helper"

module InvoiceSources
  class Xero
    class IdentityOauthClientTest < ActiveSupport::TestCase
      setup do
        @configuration = Struct.new(
          :client_id,
          :client_secret,
          :authorization_uri,
          :connections_uri,
          :jwks_uri,
          :redirect_uri,
          :scopes
        ).new(
          "client-123",
          "secret-123",
          URI("https://login.xero.test/authorize"),
          URI("https://api.xero.test/connections"),
          URI("https://identity.xero.test/jwks"),
          "https://example.com/xero/callback",
          "default scope"
        )
        @client = OauthClient.new(config: @configuration)
      end

      test "authorization URL includes the OIDC nonce and requested scopes" do
        url = @client.authorization_url(
          state: "signed-state",
          nonce: "oidc-nonce",
          redirect_uri: "https://example.com/signup/xero/callback",
          scopes: %w[openid profile email]
        )
        params = Rack::Utils.parse_query(URI(url).query)

        assert_equal "signed-state", params.fetch("state")
        assert_equal "oidc-nonce", params.fetch("nonce")
        assert_equal "openid profile email", params.fetch("scope")
      end

      test "connections are restricted to the current authorization event" do
        stub_request(:get, "https://api.xero.test/connections?authEventId=auth-event-123")
          .with(headers: { "Authorization" => "Bearer access-token" })
          .to_return(status: 200, body: [ { id: "connection-123" } ].to_json)

        connections = @client.connections(
          access_token: "access-token",
          auth_event_id: "auth-event-123"
        )

        assert_equal "connection-123", connections.sole.fetch("id")
      end

      test "loads Xero signing keys without sending an access token" do
        stub_request(:get, "https://identity.xero.test/jwks")
          .with { |request| request.headers["Authorization"].blank? }
          .to_return(status: 200, body: { keys: [ { kid: "key-123" } ] }.to_json)

        assert_equal "key-123", @client.jwks.fetch("keys").sole.fetch("kid")
      end
    end
  end
end

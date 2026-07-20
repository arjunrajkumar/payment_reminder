require "test_helper"

class Xero::AuthorizationTest < ActiveSupport::TestCase
  test "verifies both tokens and returns only organizations from this authorization event" do
    client = FakeClient.new
    verifier = FakeVerifier.new

    result = Xero::Authorization.new(client:, verifier:).complete!(
      code: "auth-code",
      redirect_uri: "https://example.com/signup/xero/callback",
      nonce: "oidc-nonce",
      include_connections: true
    )

    assert_equal "xero-user-123", result.identity.subject
    assert_equal "auth-event-123", result.authentication_event_id
    assert_equal [ "current-organization" ], result.connections.pluck("id")
    assert_equal "auth-code", client.exchanged_code
    assert_equal "oidc-nonce", verifier.verified_nonce
    assert_equal "access-token", client.connections_access_token
    assert_equal "auth-event-123", client.connections_auth_event_id
  end

  test "identity-only authorization does not inspect the access token or connections" do
    client = FakeClient.new
    verifier = FakeVerifier.new

    result = Xero::Authorization.new(client:, verifier:).complete!(
      code: "auth-code",
      redirect_uri: "https://example.com/session/xero/callback",
      nonce: "oidc-nonce",
      include_connections: false
    )

    assert_equal [], result.connections
    assert_nil result.authentication_event_id
    assert_not verifier.access_token_verified
    assert_not client.connections_called
  end

  test "rejects identity and access tokens issued for different Xero users" do
    client = FakeClient.new
    verifier = FakeVerifier.new
    verifier.access_subject = "different-xero-user"

    assert_raises Xero::Authorization::Error do
      Xero::Authorization.new(client:, verifier:).complete!(
        code: "auth-code",
        redirect_uri: "https://example.com/signup/xero/callback",
        nonce: "oidc-nonce",
        include_connections: true
      )
    end

    assert_not client.connections_called
  end

  private
    class FakeVerifier
      attr_reader :verified_nonce
      attr_accessor :access_token_verified, :access_subject

      def verify_identity!(token, nonce:)
        raise "unexpected identity token" unless token == "id-token"

        @verified_nonce = nonce
        Xero::VerifiedIdentity.new(
          subject: "xero-user-123",
          email: "owner@example.com",
          given_name: "Owner",
          family_name: "Person"
        )
      end

      def verify_access!(token)
        raise "unexpected access token" unless token == "access-token"

        self.access_token_verified = true
        Xero::TokenVerifier::Access.new(
          authentication_event_id: "auth-event-123",
          subject: access_subject || "xero-user-123"
        )
      end
    end

    class FakeClient
      attr_reader :exchanged_code, :connections_access_token, :connections_auth_event_id
      attr_accessor :connections_called

      def exchange_code(code:, redirect_uri:)
        raise "unexpected redirect URI" unless redirect_uri.include?("/xero/callback")

        @exchanged_code = code
        {
          "id_token" => "id-token",
          "access_token" => "access-token"
        }
      end

      def connections(access_token:, auth_event_id:)
        self.connections_called = true
        @connections_access_token = access_token
        @connections_auth_event_id = auth_event_id

        [
          connection("current-organization", "ORGANISATION", "auth-event-123"),
          connection("current-practice", "PRACTICE", "auth-event-123"),
          connection("stale-organization", "ORGANISATION", "old-auth-event"),
          connection("unattributed-organization", "ORGANISATION", nil)
        ]
      end

      private
        def connection(id, tenant_type, auth_event_id)
          {
            "id" => id,
            "tenantId" => "tenant-#{id}",
            "tenantName" => id.humanize,
            "tenantType" => tenant_type,
            "authEventId" => auth_event_id
          }
        end
    end
end

require "test_helper"
require "jwt"

class Xero::TokenVerifierTest < ActiveSupport::TestCase
  setup do
    @private_key = OpenSSL::PKey::RSA.generate(2048)
    @jwk = JWT::JWK.new(@private_key)
    @configuration = Struct.new(:client_id, :issuer, :resources_audience).new(
      "xero-client-id",
      "https://identity.xero.com",
      "https://identity.xero.com/resources"
    )
    @verifier = Xero::TokenVerifier.new(
      config: @configuration,
      jwks_loader: ->(_options = {}) { { keys: [ @jwk.export ] } }
    )
  end

  test "verifies an identity token and returns trusted profile claims" do
    token = encode(
      standard_claims.merge(
        "aud" => @configuration.client_id,
        "sub" => "xero-user-123",
        "email" => "owner@example.com",
        "given_name" => "Owner",
        "family_name" => "Person",
        "nonce" => "oidc-nonce"
      )
    )

    identity = @verifier.verify_identity!(token, nonce: "oidc-nonce")

    assert_equal "xero-user-123", identity.subject
    assert_equal "owner@example.com", identity.email
    assert_equal "Owner Person", identity.name
  end

  test "rejects an identity token with a different nonce" do
    token = encode(
      standard_claims.merge(
        "aud" => @configuration.client_id,
        "sub" => "xero-user-123",
        "email" => "owner@example.com",
        "nonce" => "other-nonce"
      )
    )

    assert_raises Xero::TokenVerifier::Error do
      @verifier.verify_identity!(token, nonce: "oidc-nonce")
    end
  end

  test "rejects an identity token with a missing nonce" do
    token = encode(
      standard_claims.merge(
        "aud" => @configuration.client_id,
        "sub" => "xero-user-123",
        "email" => "owner@example.com"
      )
    )

    assert_raises Xero::TokenVerifier::Error do
      @verifier.verify_identity!(token, nonce: "oidc-nonce")
    end
  end

  test "rejects an expired identity token" do
    token = encode(
      standard_claims.merge(
        "aud" => @configuration.client_id,
        "sub" => "xero-user-123",
        "email" => "owner@example.com",
        "nonce" => "oidc-nonce",
        "exp" => 2.minutes.ago.to_i
      )
    )

    assert_raises Xero::TokenVerifier::Error do
      @verifier.verify_identity!(token, nonce: "oidc-nonce")
    end
  end

  test "rejects an identity token from a different issuer" do
    token = encode(
      standard_claims.merge(
        "iss" => "https://attacker.example",
        "aud" => @configuration.client_id,
        "sub" => "xero-user-123",
        "email" => "owner@example.com",
        "nonce" => "oidc-nonce"
      )
    )

    assert_raises Xero::TokenVerifier::Error do
      @verifier.verify_identity!(token, nonce: "oidc-nonce")
    end
  end

  test "rejects an identity token with an invalid signature" do
    token = encode(
      standard_claims.merge(
        "aud" => @configuration.client_id,
        "sub" => "xero-user-123",
        "email" => "owner@example.com",
        "nonce" => "oidc-nonce"
      ),
      private_key: OpenSSL::PKey::RSA.generate(2048)
    )

    assert_raises Xero::TokenVerifier::Error do
      @verifier.verify_identity!(token, nonce: "oidc-nonce")
    end
  end

  test "an unknown signing key triggers one invalidating JWKS refetch" do
    unknown_key = OpenSSL::PKey::RSA.generate(2048)
    unknown_jwk = JWT::JWK.new(unknown_key)
    loader_calls = []
    verifier = Xero::TokenVerifier.new(
      config: @configuration,
      jwks_loader: ->(options = {}) do
        loader_calls << options
        { keys: [ @jwk.export ] }
      end
    )
    token = JWT.encode(
      standard_claims.merge(
        "aud" => @configuration.client_id,
        "sub" => "xero-user-123",
        "email" => "owner@example.com",
        "nonce" => "oidc-nonce"
      ),
      unknown_key,
      "RS256",
      kid: unknown_jwk.kid
    )

    assert_raises Xero::TokenVerifier::Error do
      verifier.verify_identity!(token, nonce: "oidc-nonce")
    end
    assert_equal 2, loader_calls.size
    assert loader_calls.second.fetch(:invalidate)
  end

  test "rejects an identity token for another client" do
    token = encode(
      standard_claims.merge(
        "aud" => "different-client",
        "sub" => "xero-user-123",
        "email" => "owner@example.com",
        "nonce" => "oidc-nonce"
      )
    )

    assert_raises Xero::TokenVerifier::Error do
      @verifier.verify_identity!(token, nonce: "oidc-nonce")
    end
  end

  test "rejects an identity token with a blank subject" do
    token = encode(
      standard_claims.merge(
        "aud" => @configuration.client_id,
        "sub" => "",
        "email" => "owner@example.com",
        "nonce" => "oidc-nonce"
      )
    )

    assert_raises Xero::TokenVerifier::Error do
      @verifier.verify_identity!(token, nonce: "oidc-nonce")
    end
  end

  test "rejects an identity token with a different authorized party" do
    token = encode(
      standard_claims.merge(
        "aud" => @configuration.client_id,
        "azp" => "different-client",
        "sub" => "xero-user-123",
        "email" => "owner@example.com",
        "nonce" => "oidc-nonce"
      )
    )

    assert_raises Xero::TokenVerifier::Error do
      @verifier.verify_identity!(token, nonce: "oidc-nonce")
    end
  end

  test "extracts the authentication event from a verified access token" do
    token = encode(
      standard_claims.except("iat").merge(
        "aud" => @configuration.resources_audience,
        "client_id" => @configuration.client_id,
        "sub" => "xero-user-123",
        "authentication_event_id" => "auth-event-123",
        "nbf" => 1.minute.ago.to_i
      )
    )

    assert_equal "auth-event-123", @verifier.authentication_event_id!(token)
  end

  test "rejects an access token issued to another client" do
    token = encode(
      standard_claims.except("iat").merge(
        "aud" => @configuration.resources_audience,
        "client_id" => "different-client",
        "sub" => "xero-user-123",
        "authentication_event_id" => "auth-event-123",
        "nbf" => 1.minute.ago.to_i
      )
    )

    assert_raises Xero::TokenVerifier::Error do
      @verifier.authentication_event_id!(token)
    end
  end

  private
    def standard_claims
      {
        "iss" => @configuration.issuer,
        "iat" => Time.current.to_i,
        "exp" => 5.minutes.from_now.to_i
      }
    end

    def encode(payload, private_key: @private_key)
      JWT.encode(payload, private_key, "RS256", kid: @jwk.kid)
    end
end

require "jwt"

module Xero
  class TokenVerifier
    class Error < StandardError; end

    ALGORITHM = "RS256"
    LEEWAY = 60
    Access = Data.define(:authentication_event_id, :subject)

    def initialize(config: InvoiceSources::Xero::Configuration.new, jwks_loader: Xero::Jwks.new)
      @config = config
      @jwks_loader = jwks_loader
    end

    def verify_identity!(token, nonce:)
      claims = decode!(
        token,
        audience: config.client_id,
        required_claims: %w[iss aud exp iat sub nonce]
      )
      verify_nonce!(claims.fetch("nonce"), nonce)
      verify_authorized_party!(claims)
      subject = verified_subject!(claims.fetch("sub"))

      Xero::VerifiedIdentity.new(
        subject:,
        email: claims["email"].to_s.strip.downcase.presence,
        given_name: claims["given_name"].to_s.strip.presence,
        family_name: claims["family_name"].to_s.strip.presence
      )
    rescue KeyError
      raise Error, "Xero identity token is missing a required claim."
    end

    def verify_access!(token)
      claims = decode!(
        token,
        audience: config.resources_audience,
        required_claims: %w[iss aud exp nbf sub client_id authentication_event_id]
      )
      verify_client_id!(claims.fetch("client_id"))
      authentication_event_id = claims.fetch("authentication_event_id").presence ||
        raise(Error, "Xero access token is missing its authorization event.")

      Access.new(
        authentication_event_id:,
        subject: verified_subject!(claims.fetch("sub"))
      )
    rescue KeyError
      raise Error, "Xero access token is missing a required claim."
    end


    def authentication_event_id!(token)
      verify_access!(token).authentication_event_id
    end

    private
      attr_reader :config, :jwks_loader

      def decode!(token, audience:, required_claims:)
        payload, = JWT.decode(
          token,
          nil,
          true,
          algorithms: [ ALGORITHM ],
          jwks: jwks_loader,
          iss: config.issuer,
          verify_iss: true,
          aud: audience,
          verify_aud: true,
          required_claims: required_claims,
          leeway: LEEWAY
        )
        verify_issued_at!(payload.fetch("iat")) if payload.key?("iat")
        payload
      rescue JWT::DecodeError, JWT::JWKError, ArgumentError, TypeError
        raise Error, "Xero returned an invalid identity token."
      end

      def verify_issued_at!(issued_at)
        valid = issued_at.is_a?(Numeric) && issued_at <= Time.current.to_f + LEEWAY
        raise Error, "Xero returned an invalid identity token." unless valid
      end

      def verified_subject!(subject)
        return subject if subject.is_a?(String) && subject.present?

        raise Error, "Xero token is missing a valid subject."
      end

      def verify_nonce!(claim, expected_nonce)
        valid = claim.present? && expected_nonce.present? &&
          ActiveSupport::SecurityUtils.secure_compare(claim.to_s, expected_nonce.to_s)
        raise Error, "Xero identity token could not be verified." unless valid
      end

      def verify_authorized_party!(claims)
        return verify_client_id!(claims["azp"]) if claims["azp"].present?

        audiences = Array(claims.fetch("aud"))
        return if audiences.one?

        verify_client_id!(claims["azp"])
      end

      def verify_client_id!(claim)
        valid = claim.present? && config.client_id.present? &&
          ActiveSupport::SecurityUtils.secure_compare(claim.to_s, config.client_id.to_s)
        raise Error, "Xero identity token could not be verified." unless valid
      end
  end
end

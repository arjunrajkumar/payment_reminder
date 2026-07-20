module Xero
  class Authorization
    class Error < StandardError; end

    Result = Data.define(:identity, :token_set, :connections, :authentication_event_id)

    def initialize(
      client: InvoiceSources::Xero::OauthClient.new,
      verifier: Xero::TokenVerifier.new
    )
      @client = client
      @verifier = verifier
    end

    def complete!(code:, redirect_uri:, nonce:, include_connections:)
      token_set = client.exchange_code(code:, redirect_uri:)
      identity = verifier.verify_identity!(token_set.fetch("id_token"), nonce:)

      if include_connections
        access = verifier.verify_access!(token_set.fetch("access_token"))
        verify_matching_subjects!(identity.subject, access.subject)
        authentication_event_id = access.authentication_event_id
        connections = organization_connections(
          client.connections(
            access_token: token_set.fetch("access_token"),
            auth_event_id: authentication_event_id
          ),
          authentication_event_id:
        )
      else
        authentication_event_id = nil
        connections = []
      end

      Result.new(identity:, token_set:, connections:, authentication_event_id:)
    rescue KeyError, InvoiceSources::Xero::OauthClient::Error, Xero::TokenVerifier::Error => error
      raise Error, error.message
    end

    private
      attr_reader :client, :verifier

      def organization_connections(connections, authentication_event_id:)
        Array(connections).select do |connection|
          organization = connection["tenantType"].to_s.casecmp?("ORGANISATION")
          matching_event = connection["authEventId"].present? &&
            ActiveSupport::SecurityUtils.secure_compare(
              connection["authEventId"].to_s,
              authentication_event_id.to_s
            )

          organization && matching_event
        end
      end

      def verify_matching_subjects!(identity_subject, access_subject)
        return if identity_subject == access_subject

        raise Error, "Xero returned tokens for different identities."
      end
  end
end

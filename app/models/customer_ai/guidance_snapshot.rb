class CustomerAi::GuidanceSnapshot
  class Stale < StandardError; end
  ERROR_MESSAGE = "This customer guidance changed; refresh and try again."

  class << self
    def token_for(signal:, idempotency_key:)
      verifier.generate(
        payload_for(signal, idempotency_key:),
        expires_in: 30.minutes,
        purpose: "customer-ai-guidance"
      )
    end

    def verify!(token:, signal:, idempotency_key:)
      payload = verified_payload(token)
      raise Stale, ERROR_MESSAGE unless
        payload == payload_for(signal, idempotency_key:)

      payload
    end

    def verify_replay!(token:, signal:, idempotency_key:)
      payload = verified_payload(token)
      expected = {
        "account_id" => signal.account_id,
        "customer_id" => signal.customer_id,
        "signal_id" => signal.id,
        "idempotency_key" => idempotency_key.to_s.strip
      }
      raise Stale, ERROR_MESSAGE unless
        expected.all? { |key, value| payload[key] == value } &&
          payload["signal_status"] == "proposed"

      payload
    end

    private
      def verified_payload(token)
        verifier.verify(
          token.to_s,
          purpose: "customer-ai-guidance"
        )
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        raise Stale, ERROR_MESSAGE
      end

      def payload_for(signal, idempotency_key:)
        profile = signal.customer.customer_ai_profile
        {
          "account_id" => signal.account_id,
          "customer_id" => signal.customer_id,
          "signal_id" => signal.id,
          "signal_status" => signal.status,
          "profile_id" => profile&.id,
          "active_revision_id" => profile&.active_guidance_revision_id,
          "profile_lock_version" => profile&.lock_version,
          "idempotency_key" => idempotency_key.to_s.strip
        }
      end

      def verifier
        Rails.application.message_verifier("customer-ai-guidance")
      end
  end
end

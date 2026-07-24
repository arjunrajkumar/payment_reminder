class ConversationEscalations::EscalationSnapshot
  ERROR_MESSAGE = "This escalation changed; refresh and try again."

  class << self
    def token_for(escalation:, idempotency_key:)
      escalation = escalation.reload
      verifier.generate(
        payload_for(
          escalation,
          idempotency_key: normalize_key(idempotency_key)
        ),
        expires_in: 30.minutes,
        purpose: "conversation-escalation-control"
      )
    end

    def verify!(token:, escalation:, idempotency_key:)
      payload = verifier.verify(
        token.to_s,
        purpose: "conversation-escalation-control"
      )
      identity = {
        "account_id" => escalation.account_id,
        "conversation_escalation_id" => escalation.id,
        "idempotency_key" => normalize_key(idempotency_key)
      }
      unless identity.all? { |key, value| payload[key] == value }
        raise ConversationEscalations::StaleControl, ERROR_MESSAGE
      end
      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise ConversationEscalations::StaleControl, ERROR_MESSAGE
    end

    def ensure_current!(payload:, escalation:)
      expected = payload_for(
        escalation,
        idempotency_key: payload.fetch("idempotency_key")
      )
      unless payload == expected
        raise ConversationEscalations::StaleControl, ERROR_MESSAGE
      end
    end

    private
      def payload_for(escalation, idempotency_key:)
        {
          "account_id" => escalation.account_id,
          "conversation_escalation_id" => escalation.id,
          "status" => escalation.status,
          "lock_version" => escalation.lock_version,
          "last_opened_at" => escalation.last_opened_at.iso8601(6),
          "idempotency_key" => idempotency_key
        }
      end

      def normalize_key(value)
        value.to_s.strip.presence ||
          raise(ArgumentError, "Idempotency key is required.")
      end

      def verifier
        Rails.application.message_verifier("conversation-escalation-control")
      end
  end
end

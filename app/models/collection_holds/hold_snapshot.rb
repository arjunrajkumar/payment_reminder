class CollectionHolds::HoldSnapshot
  ERROR_MESSAGE = "This collection hold changed; refresh and try again."

  class << self
    def token_for(hold:, idempotency_key:)
      hold = hold.reload
      verifier.generate(
        payload_for(hold, idempotency_key: normalize_key(idempotency_key)),
        expires_in: 30.minutes,
        purpose: "collection-hold-control"
      )
    end

    def verify!(token:, hold:, idempotency_key:)
      payload = verifier.verify(token.to_s, purpose: "collection-hold-control")
      identity = {
        "account_id" => hold.account_id,
        "conversation_id" => hold.conversation_id,
        "invoice_id" => hold.invoice_id,
        "collection_hold_id" => hold.id,
        "idempotency_key" => normalize_key(idempotency_key)
      }
      unless identity.all? { |key, value| payload[key] == value }
        raise CollectionHolds::StaleControl, ERROR_MESSAGE
      end
      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise CollectionHolds::StaleControl, ERROR_MESSAGE
    end

    def ensure_current!(payload:, hold:)
      expected = payload_for(
        hold,
        idempotency_key: payload.fetch("idempotency_key")
      )
      raise CollectionHolds::StaleControl, ERROR_MESSAGE unless payload == expected
    end

    private
      def payload_for(hold, idempotency_key:)
        {
          "account_id" => hold.account_id,
          "conversation_id" => hold.conversation_id,
          "invoice_id" => hold.invoice_id,
          "collection_hold_id" => hold.id,
          "status" => hold.status,
          "lock_version" => hold.lock_version,
          "idempotency_key" => idempotency_key
        }
      end

      def normalize_key(value)
        value.to_s.strip.presence ||
          raise(ArgumentError, "Idempotency key is required.")
      end

      def verifier
        Rails.application.message_verifier("collection-hold-control")
      end
  end
end

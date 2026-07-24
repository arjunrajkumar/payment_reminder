class ConversationActions::ActionSnapshot
  ERROR_MESSAGE = "This action changed; refresh and try again."

  class << self
    def token_for(action:, idempotency_key:)
      action = action.reload
      verifier.generate(
        payload_for(action, idempotency_key: normalize_key(idempotency_key)),
        expires_in: 30.minutes,
        purpose: "conversation-action-control"
      )
    end

    def verify!(
      token:,
      action:,
      idempotency_key:
    )
      payload = verifier.verify(
        token.to_s,
        purpose: "conversation-action-control"
      )
      expected_identity = {
        "account_id" => action.account_id,
        "action_id" => action.id,
        "idempotency_key" => normalize_key(idempotency_key)
      }
      unless expected_identity.all? { |key, value| payload[key] == value }
        raise ConversationActions::StaleControl, ERROR_MESSAGE
      end

      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise ConversationActions::StaleControl, ERROR_MESSAGE
    end

    def ensure_current!(payload:, action:)
      unless payload == payload_for(
        action,
        idempotency_key: payload.fetch("idempotency_key")
      )
        raise ConversationActions::StaleControl, ERROR_MESSAGE
      end
    end

    private
      def payload_for(action, idempotency_key:)
        revision = action.current_revision
        {
          "account_id" => action.account_id,
          "action_id" => action.id,
          "revision_id" => revision&.id,
          "revision_number" => revision&.revision_number,
          "status" => action.status,
          "lock_version" => action.lock_version,
          "idempotency_key" => idempotency_key
        }
      end

      def normalize_key(value)
        value.to_s.strip.presence ||
          raise(ArgumentError, "Idempotency key is required.")
      end

      def verifier
        Rails.application.message_verifier("conversation-action-control")
      end
  end
end

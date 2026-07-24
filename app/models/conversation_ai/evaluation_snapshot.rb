class ConversationAi::EvaluationSnapshot
  class Stale < StandardError; end
  ERROR_MESSAGE = "This AI analysis changed; refresh and try again."

  class << self
    def token_for(interpretation:, idempotency_key:)
      verifier.generate(
        payload_for(interpretation, idempotency_key:),
        expires_in: 30.minutes,
        purpose: "conversation-ai-evaluation"
      )
    end

    def verify!(token:, interpretation:, idempotency_key:)
      payload = verifier.verify(
        token.to_s,
        purpose: "conversation-ai-evaluation"
      )
      raise Stale, ERROR_MESSAGE unless
        payload == payload_for(interpretation, idempotency_key:)

      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise Stale, ERROR_MESSAGE
    end

    private
      def payload_for(interpretation, idempotency_key:)
        plan = interpretation.conversation_ai_plan
        {
          "account_id" => interpretation.account_id,
          "conversation_id" => interpretation.conversation_id,
          "work_unit_message_ids" => Conversations::ReviewWorkUnit
            .message_scope_for_conversation(
              conversation: interpretation.conversation
            )
            .order(:id)
            .pluck(:id),
          "interpretation_id" => interpretation.id,
          "interpretation_lock_version" => interpretation.lock_version,
          "plan_id" => plan&.id,
          "plan_status" => plan&.status,
          "prompt_version" => interpretation.semantic_prompt_version,
          "schema_version" => interpretation.result_schema_version,
          "planner_version" => interpretation.planner_version,
          "idempotency_key" => idempotency_key.to_s.strip
        }
      end

      def verifier
        Rails.application.message_verifier("conversation-ai-evaluation")
      end
  end
end

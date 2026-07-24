class Conversations::WorkUnitSnapshot
  ERROR_MESSAGE = "Conversation changed; refresh and try again."

  class Stale < StandardError; end

  class << self
    def token_for(conversation:)
      conversation = conversation.canonical
      verifier.generate(
        payload_for(conversation),
        expires_in: 30.minutes,
        purpose: "conversation-work-unit"
      )
    end

    def verify!(token:, conversation:)
      conversation = conversation.canonical
      payload = verifier.verify(
        token.to_s,
        purpose: "conversation-work-unit"
      )
      raise Stale, ERROR_MESSAGE unless payload == payload_for(conversation)

      payload
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise Stale, ERROR_MESSAGE
    end

    private
      def payload_for(conversation)
        {
          "account_id" => conversation.account_id,
          "conversation_id" => conversation.id,
          "message_ids" => Conversations::ReviewWorkUnit
            .message_scope_for_conversation(conversation:)
            .order(:id)
            .pluck(:id),
          "execution_issues" => execution_issues(conversation),
          "open_escalations" => open_escalations(conversation)
        }
      end

      def execution_issues(conversation)
        ConversationActionExecution
          .joins(:conversation_action)
          .where(
            conversation_actions: {
              conversation_id: Conversations::ReviewWorkUnit
                .workflow_conversation_ids_for(conversation:)
            },
            attention_required: true
          )
          .order(:id)
          .pluck(:id, :attention_version, :status, :lock_version)
          .map do |id, attention_version, status, lock_version|
            {
              "id" => id,
              "attention_version" => attention_version,
              "status" => status,
              "lock_version" => lock_version
            }
          end
      end

      def open_escalations(conversation)
        conversation.account.conversation_escalations
          .where(
            conversation_id: Conversations::ReviewWorkUnit
              .workflow_conversation_ids_for(conversation:)
          )
          .status_open
          .order(:id)
          .pluck(:id, :lock_version)
          .map do |id, lock_version|
            { "id" => id, "lock_version" => lock_version }
          end
      end

      def verifier
        Rails.application.message_verifier("conversation-work-unit")
      end
  end
end

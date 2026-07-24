class ConversationAi::EligibilityHook
  class << self
    def for_message(message)
      ConversationAi::AnalysisRequest.enqueue_for(message)
    rescue StandardError => error
      Rails.logger.error(
        "conversation_ai.eligibility_hook_failed " \
          "message_id=#{message.id} error=#{error.class.name}"
      )
      nil
    end

    def for_conversation(conversation)
      Conversations::ReviewWorkUnit.message_scope_for_conversation(
        conversation:
      )
        .direction_inbound
        .status_received
        .find_each { |message| for_message(message) }
    rescue Conversations::ReviewWorkUnit::SplitInvoiceWorkUnit
      nil
    end
  end
end

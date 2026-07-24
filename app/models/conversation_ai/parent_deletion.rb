class ConversationAi::ParentDeletion
  class << self
    def destroy_interpretations!(scope)
      interpretation_ids = scope.pluck(:id)
      return if interpretation_ids.empty?

      ConversationAiEvaluation.where(conversation_interpretation_id: interpretation_ids).delete_all
      release_guidance_signal_references!(interpretation_ids)
      CustomerAiSignal.where(conversation_interpretation_id: interpretation_ids).delete_all
      ConversationAiPlan.where(conversation_interpretation_id: interpretation_ids).delete_all
      ConversationAiInvocation.where(conversation_interpretation_id: interpretation_ids).delete_all
      ConversationInterpretation.where(supersedes_interpretation_id: interpretation_ids)
        .update_all(supersedes_interpretation_id: nil)
      ConversationInterpretation.where(id: interpretation_ids).delete_all
    end

    private
      def release_guidance_signal_references!(interpretation_ids)
        signal_ids = CustomerAiSignal
          .where(conversation_interpretation_id: interpretation_ids)
          .select(:id)

        CustomerAiGuidanceRevision.where(source_signal_id: signal_ids)
          .update_all(source_signal_id: nil)
      end
  end
end

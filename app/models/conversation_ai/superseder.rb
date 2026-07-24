class ConversationAi::Superseder
  class << self
    def supersede_older!(current:, work_unit:, at: Time.current)
      source = current.source_message
      occurred_at = source.occurred_at
      scope = current.account.conversation_interpretations
        .where(conversation_id: work_unit.conversation_ids)
        .where(status: %i[succeeded skipped])
        .where.not(id: current.id)
        .joins(:source_message)
        .where(
          <<~SQL.squish,
            COALESCE(
              conversation_messages.received_at,
              conversation_messages.sent_at,
              conversation_messages.created_at
            ) < :occurred_at
            OR (
              COALESCE(
                conversation_messages.received_at,
                conversation_messages.sent_at,
                conversation_messages.created_at
              ) = :occurred_at
              AND conversation_messages.id < :source_message_id
            )
            OR (
              conversation_messages.id = :source_message_id
              AND conversation_interpretations.id < :interpretation_id
            )
          SQL
          occurred_at:,
          source_message_id: source.id,
          interpretation_id: current.id
        )
      ids = scope.pluck(:id)
      return if ids.empty?

      ConversationAiPlan.where(
        conversation_interpretation_id: ids,
        status: :current
      ).update_all(
        status: ConversationAiPlan.statuses.fetch(:superseded),
        superseded_at: at,
        updated_at: at
      )
      ConversationInterpretation.where(id: ids).update_all(
        status: ConversationInterpretation.statuses.fetch(:superseded),
        superseded_at: at,
        updated_at: at
      )
      ConversationInterpretation.where(id: ids).find_each do |interpretation|
        ConversationEvent.record_ai_once!(
          interpretation:,
          role: "superseded-by:#{current.id}",
          kind: :conversation_ai_analysis_superseded,
          metadata: {
            "superseded_by_interpretation_id" => current.id
          },
          created_at: at
        )
      end
    end
  end
end

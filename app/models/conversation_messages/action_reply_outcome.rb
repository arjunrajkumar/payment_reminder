class ConversationMessages::ActionReplyOutcome
  class << self
    def finalize!(message, at: Time.current)
      message_id = message&.id
      execution_id = message&.conversation_action_execution_id
      return false unless message_id && execution_id

      finalized = false
      execution = ConversationActionExecution.find_by(id: execution_id)
      return false unless execution
      action = execution.conversation_action

      Conversations::ReviewWorkUnit.with_reconciled_workflow_owner(
        conversation: action.conversation,
        at:
      ) do |conversation, _work_unit|
        execution.account.conversation_actions.lock.find(action.id)
        execution.lock!
        current_message = execution.account.conversation_messages.lock
          .find(message_id)
        next unless current_message.action_reply?
        next unless current_message.conversation_action_execution_id ==
          execution.id
        next unless current_message.status_sent? ||
          current_message.status_failed?

        finalized = if current_message.status_sent?
          finalize_success!(
            execution:,
            message: current_message,
            at:
          )
        elsif current_message.delivery_uncertain?
          finalize_uncertain!(
            execution:,
            message: current_message,
            at:
          )
        else
          finalize_failure!(
            execution:,
            message: current_message,
            at:
          )
        end
        Conversations::Attention.recompute!(
          conversation:,
          at:
        ) if finalized
      end
      finalized
    end

    def needing_finalization
      ConversationMessage
        .where(kind: ConversationMessages::ThreadedReply::ACTION_KINDS)
        .where(status: %i[sent failed])
        .joins(:conversation_action_execution)
        .where(
          <<~SQL.squish
            conversation_action_executions.finalization_status = 'pending'
            OR (
              conversation_messages.status = 'sent'
              AND conversation_action_executions.status <> 'succeeded'
            )
            OR (
              conversation_messages.status = 'failed'
              AND conversation_action_executions.status = 'awaiting_delivery'
            )
          SQL
        )
    end

    private
      def finalize_success!(execution:, message:, at:)
        previous_status = execution.status
        reconciled = previous_status.in?(%w[failed uncertain])
        delivery_escalation = execution.delivery_escalation
        if delivery_escalation&.status_open?
          delivery_escalation.resolve_by_system!(
            reason: "Gmail SENT evidence confirmed delivery.",
            idempotency_key:
              "action-execution-#{execution.id}-gmail-sent",
            at:
          )
        end
        changed = execution.finalize_delivery!(
          outcome: :succeeded,
          message:,
          at:,
          delivery_escalation:,
          authoritative_sent: reconciled
        )
        return false unless changed

        ConversationEvent.record_execution_once!(
          execution:,
          role: reconciled ?
            "delivery:sent_reconciled" :
            "delivery:succeeded",
          conversation_message: message,
          kind: reconciled ?
            :conversation_action_execution_reconciled :
            :conversation_action_execution_succeeded,
          metadata: { "delivery_reconciled" => reconciled },
          created_at: at
        )
        true
      end

      def finalize_uncertain!(execution:, message:, at:)
        return false unless execution.status_awaiting_delivery?

        changed = execution.finalize_delivery!(
          outcome: :uncertain,
          message:,
          at:,
          authoritative_sent: false
        )
        return false unless changed

        ConversationEvent.record_execution_once!(
          execution:,
          role: "delivery:uncertain",
          conversation_message: message,
          kind: :conversation_action_execution_unconfirmed,
          metadata: {},
          created_at: at
        )
        true
      end

      def finalize_failure!(execution:, message:, at:)
        return false unless execution.status_awaiting_delivery?

        escalation = ConversationEscalations::Opening.call(
          conversation: message.conversation,
          category: :delivery_failure,
          priority: :high,
          summary: "An approved action reply could not be delivered.",
          details: "The local action effect, if any, remains applied.",
          source_message: message.reply_to_message,
          conversation_action: execution.conversation_action,
          opened_by_kind: :system,
          idempotency_key:
            "action-execution:#{execution.id}:delivery-failure",
          at:
        )
        changed = execution.finalize_delivery!(
          outcome: :failed,
          message:,
          at:,
          delivery_escalation: escalation,
          authoritative_sent: false
        )
        return false unless changed

        ConversationEvent.record_execution_once!(
          execution:,
          role: "delivery:failed",
          conversation_message: message,
          kind: :conversation_action_execution_failed,
          metadata: {
            "failure_category" => "delivery_failed",
            "conversation_escalation_id" => escalation.id
          },
          created_at: at
        )
        true
      end
  end
end

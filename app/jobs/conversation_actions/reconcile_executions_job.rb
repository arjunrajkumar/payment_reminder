class ConversationActions::ReconcileExecutionsJob < ApplicationJob
  include Sentry::Cron::MonitorCheckIns

  BATCH_SIZE = 100

  queue_as :default

  sentry_monitor_check_ins(
    slug: "reconcile-conversation-action-executions",
    monitor_config: Sentry::Cron::MonitorConfig.from_interval(
      15,
      :minute,
      checkin_margin: 5,
      max_runtime: 10
    )
  )

  def perform
    recover_stale_execution_scheduling
    recover_stale_execution_claims
    fail_exhausted_execution_claims
    schedule_due_executions
    recover_stale_reply_scheduling
    schedule_due_replies
    finalize_delivery_outcomes
  end

  private
    def recover_stale_execution_scheduling
      before = ConversationActionExecution::STALE_SCHEDULING_CLAIM_AFTER.ago
      ConversationActionExecution
        .stale_scheduling_claims(before:)
        .find_each(batch_size: BATCH_SIZE) do |execution|
          execution.recover_stale_scheduling_claim!(
            before:,
            at: Time.current
          )
        end
      ConversationActionExecution
        .stale_enqueued_scheduling(before:)
        .find_each(batch_size: BATCH_SIZE) do |execution|
          execution.recover_stale_scheduling_claim!(
            before:,
            at: Time.current
          )
        end
    end

    def recover_stale_execution_claims
      before = ConversationActionExecution::STALE_CLAIM_AFTER.ago
      ConversationActionExecution
        .stale_running(before:)
        .find_each(batch_size: BATCH_SIZE) do |execution|
          execution.recover_stale_execution_claim!(
            before:,
            at: Time.current
          )
        end
    end

    def fail_exhausted_execution_claims
      ConversationActionExecution.status_pending
        .where(attempts: ConversationActionExecution::MAXIMUM_ATTEMPTS..)
        .find_each(batch_size: BATCH_SIZE) do |execution|
          ConversationActions::Executor.fail_exhausted!(execution)
        end
    end

    def schedule_due_executions
      ConversationActionExecution.due_for_scheduling
        .find_each(batch_size: BATCH_SIZE) do |execution|
          ConversationActions::ExecutionRequest.enqueue(execution)
        end
    end

    def recover_stale_reply_scheduling
      before = ConversationMessage::STALE_REPLY_SCHEDULING_AFTER.ago
      ConversationMessage.stale_action_reply_scheduling(before:)
        .find_each(batch_size: BATCH_SIZE) do |message|
          message.recover_stale_reply_scheduling!(
            before:,
            at: Time.current
          )
        end
      ConversationMessage.stale_enqueued_action_reply_scheduling(before:)
        .find_each(batch_size: BATCH_SIZE) do |message|
          message.recover_stale_reply_scheduling!(
            before:,
            at: Time.current
          )
        end
    end

    def schedule_due_replies
      ConversationMessage.due_action_reply_scheduling
        .find_each(batch_size: BATCH_SIZE) do |message|
          ConversationMessages::ActionReplyRequest.enqueue(message)
        end
    end

    def finalize_delivery_outcomes
      ConversationMessages::ActionReplyOutcome.needing_finalization
        .find_each(batch_size: BATCH_SIZE) do |message|
          ConversationMessages::ActionReplyOutcome.finalize!(message)
        end
    end
end

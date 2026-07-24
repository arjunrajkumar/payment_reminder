class ConversationAi::Reconciler
  BATCH_SIZE = 100

  class << self
    def call(at: Time.current)
      new(at:).call
    end
  end

  def initialize(at:)
    @at = at
  end

  def call
    release_stale_scheduling
    recover_stale_claims
    schedule_due
    schedule_retries
    finalize_completed
    reconcile_missing
    cancel_disabled
  end

  private
    attr_reader :at

    def release_stale_scheduling
      ConversationInterpretation.stale_scheduling(at)
        .in_batches(of: BATCH_SIZE) do |batch|
          batch.update_all(
            scheduling_status: ConversationInterpretation
              .scheduling_statuses.fetch(:reserved),
            scheduling_token: nil,
            scheduling_claimed_at: nil,
            next_scheduling_at: at,
            last_scheduling_error: "stale scheduling owner released",
            updated_at: at
          )
        end
    end

    def recover_stale_claims
      ConversationInterpretation.stale_claims(at).find_each(batch_size: BATCH_SIZE) do |record|
        record.with_lock do
          next unless record.status_running? &&
            record.claimed_at < at - ConversationInterpretation::STALE_CLAIM_AFTER

          close_started_invocations!(record, "stale_claim")
          record.update!(
            status: :pending,
            scheduling_status: :reserved,
            scheduling_enqueued_at: nil,
            scheduling_consumed_at: nil,
            next_scheduling_at: at,
            next_retry_at: at,
            claim_token: nil,
            claimed_at: nil,
            failure_category: "stale_claim",
            failure_reason: "A stale provider claim was released."
          )
        end
      end
    end

    def schedule_due
      ConversationInterpretation.due_scheduling(at)
        .find_each(batch_size: BATCH_SIZE) do |record|
          ConversationAi::AnalysisRequest.schedule(record)
        end
    end

    def schedule_retries
      ConversationInterpretation.due_retry(at)
        .find_each(batch_size: BATCH_SIZE) do |record|
          ConversationAi::AnalysisRequest.schedule(record)
        end
    end

    def finalize_completed
      ConversationInterpretation.needs_finalization
        .joins(:conversation_ai_plan)
        .find_each(batch_size: BATCH_SIZE) do |record|
          record.with_lock do
            next unless record.finalized_at.nil? &&
              record.status.in?(%w[succeeded skipped]) &&
              record.conversation_ai_plan.present?

            record.update_column(:finalized_at, at)
            event_kind = record.status_skipped? ?
              :conversation_ai_analysis_skipped :
              :conversation_ai_analysis_completed
            ConversationEvent.record_ai_once!(
              interpretation: record,
              role: record.status_skipped? ? "skipped" : "completed",
              kind: event_kind,
              metadata: {
                "conversation_ai_plan_id" =>
                  record.conversation_ai_plan.id,
                "decision" => record.conversation_ai_plan.decision,
                "reconciled" => true
              },
              created_at: at
            )
            ConversationEvent.record_ai_once!(
              interpretation: record,
              role: "plan",
              kind: :conversation_ai_plan_created,
              metadata: {
                "conversation_ai_plan_id" =>
                  record.conversation_ai_plan.id,
                "decision" => record.conversation_ai_plan.decision,
                "reconciled" => true
              },
              created_at: at
            )
          end
        end
    end

    def reconcile_missing
      Account.conversation_ai_mode_shadow.find_each do |account|
        messages = account.conversation_messages
          .direction_inbound
          .status_received
          .where.not(email_connection_id: nil)
          .where(received_at: account.conversation_ai_enabled_at..)
          .where.not(
            id: account.conversation_interpretations.select(:source_message_id)
          )
        matched = messages.where(matching_status: :matched)
        manually_matched = messages
          .where(
            matching_status: :ambiguous,
            review_outcome: :manual_match
          )
          .where.not(reviewed_at: nil)
        matched.or(manually_matched)
          .order(:id)
          .limit(BATCH_SIZE)
          .each { |message| ConversationAi::AnalysisRequest.enqueue_for(message) }
      end
    end

    def cancel_disabled
      ConversationInterpretation
        .joins(:account)
        .where(accounts: { conversation_ai_mode: :off })
        .where(status: %i[pending running])
        .find_each(batch_size: BATCH_SIZE) do |record|
          record.with_lock do
            next unless record.status.in?(%w[pending running])

            close_started_invocations!(record, "mode_disabled")
            record.update!(
              status: :canceled,
              scheduling_status: :canceled,
              scheduling_token: nil,
              scheduling_claimed_at: nil,
              claim_token: nil,
              claimed_at: nil,
              failure_category: "mode_disabled",
              failure_reason: "Shadow mode was disabled.",
              canceled_at: at
            )
          end
        end
    end

    def close_started_invocations!(interpretation, category)
      interpretation.conversation_ai_invocations.status_started.find_each do |invocation|
        invocation.update!(
          status: :superseded,
          failure_category: category,
          failure_class: self.class.name,
          failure_message: "Claim ownership ended during reconciliation.",
          finished_at: at
        )
      end
    end
end

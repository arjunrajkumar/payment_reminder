class ConversationActions::ExecutionRequest
  BASE_BACKOFF = 1.minute

  class << self
    def enqueue(execution, at: Time.current)
      claim = execution.claim_scheduling!(at:)
      return false unless claim

      job = ConversationActions::ExecutionJob.new(
        execution.id,
        claim.generation
      )
      enqueued = job.enqueue
      unless enqueued
        release_failure(
          execution:,
          claim:,
          error: "The execution job was not accepted.",
          at:
        )
        return false
      end

      execution.record_scheduled!(claim, at:)
    rescue StandardError => error
      release_failure(
        execution:,
        claim:,
        error: "The execution job could not be scheduled: #{error.class.name}.",
        at:
      ) if claim
      false
    end

    private
      def release_failure(execution:, claim:, error:, at:)
        outcome = execution.release_scheduling!(
          claim,
          error:,
          next_attempt_at: at + backoff_for(claim.attempt)
        )
        ConversationActions::Executor.fail_scheduling_exhausted!(
          execution,
          at:
        ) if outcome == :exhausted
      end

      def backoff_for(attempt)
        BASE_BACKOFF * (2**([ attempt.to_i - 1, 0 ].max))
      end
  end
end

class ConversationMessages::ActionReplyRequest
  BASE_BACKOFF = 1.minute

  class << self
    def enqueue(message, at: Time.current)
      return false unless message&.action_reply?

      job = ConversationMessages::ThreadedReplyJob.new(
        message.account_id,
        message.id,
        message.requested_provider_thread_id,
        nil
      )
      claim = message.claim_reply_scheduling!(
        job_id: job.job_id,
        at:
      )
      return false unless claim

      job.arguments[3] = claim.generation
      enqueued = job.enqueue
      unless enqueued
        release_failure(
          message:,
          claim:,
          error: "The reply job was not accepted.",
          at:
        )
        return false
      end

      message.record_reply_scheduled!(claim, at:)
    rescue StandardError => error
      release_failure(
        message:,
        claim:,
        error: "The reply job could not be scheduled: #{error.class.name}.",
        at:
      ) if claim
      false
    end

    private
      def release_failure(message:, claim:, error:, at:)
        outcome = message.release_reply_scheduling!(
          claim,
          error:,
          next_attempt_at: at + backoff_for(claim.attempt)
        )
        return unless outcome == :exhausted

        message.mark_delivery_failed!(
          job_id: message.delivery_job_id,
          failure_reason:
            "The approved reply could not be scheduled after retrying.",
          delivery_uncertain: false
        )
        ConversationMessages::ActionReplyOutcome.finalize!(message)
      end

      def backoff_for(attempt)
        BASE_BACKOFF * (2**([ attempt.to_i - 1, 0 ].max))
      end
  end
end

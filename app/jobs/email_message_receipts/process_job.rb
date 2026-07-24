class EmailMessageReceipts::ProcessJob < ApplicationJob
  class UnexpectedProcessingError < StandardError; end
  class ProcessedFinalizationError < StandardError; end

  MAX_ATTEMPTS = 10

  queue_as :default

  limits_concurrency(
    to: 1,
    key: ->(email_message_receipt_id, *) {
      EmailMessageReceipt.processing_concurrency_key(email_message_receipt_id)
    },
    duration: 15.minutes,
    group: "GmailMessageReceipt",
    on_conflict: :block
  )

  retry_on EmailConnection::Errors::TemporaryProviderError,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.release_processing_enqueue_reservation
      raise error
    end
  retry_on ActiveRecord::Deadlocked,
    ActiveRecord::LockWaitTimeout,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.release_processing_enqueue_reservation
      raise error
    end
  retry_on ProcessedFinalizationError,
    wait: :polynomially_longer,
    attempts: 5 do |job, _error|
      job.release_post_processing_ownership
    end

  around_enqueue do |job, enqueue|
    enqueue.call
  ensure
    unless job.successfully_enqueued?
      job.release_processing_enqueue_reservation
      job.release_post_processing_ownership
    end
  end

  def self.enqueue(receipt)
    provider_account_id = receipt.provider_account_id
    email_connection_generation = receipt.email_connection_generation
    job = new(receipt.id, provider_account_id, email_connection_generation)
    return false unless receipt.reserve_processing_enqueue!(
      job_id: job.job_id,
      provider_account_id:,
      email_connection_generation:
    )

    enqueued = job.enqueue
    return enqueued if enqueued

    raise(job.enqueue_error || ActiveJob::EnqueueError.new("Could not enqueue Gmail message receipt"))
  rescue StandardError
    receipt.release_processing_enqueue!(job_id: job.job_id) if receipt && job
    raise
  end

  def self.enqueue_post_processing(receipt)
    job = new(
      receipt.id,
      receipt.provider_account_id,
      receipt.email_connection_generation
    )
    return false unless receipt.reserve_post_processing_enqueue!(
      job_id: job.job_id
    )

    enqueued = job.enqueue
    return enqueued if enqueued

    raise(
      job.enqueue_error ||
        ActiveJob::EnqueueError.new(
          "Could not enqueue Gmail receipt finalization"
        )
    )
  rescue StandardError
    receipt.release_post_processing_ownership!(job_id: job.job_id) if
      receipt && job
    raise
  end

  def perform(email_message_receipt_id, provider_account_id, email_connection_generation)
    receipt = EmailMessageReceipt.find_by(id: email_message_receipt_id)
    return unless receipt
    unless receipt.mailbox_snapshot?(
      provider_account_id:,
      email_connection_generation:
    )
      receipt.release_processing_enqueue!(job_id:)
      return
    end
    if receipt.status_processed?
      if receipt.post_processing_finalized_at?
        receipt.release_post_processing_ownership!(job_id:)
        return
      end
      return unless receipt.claim_post_processing!(job_id:)

      finalize_processed_receipt!(receipt, job_id:)
      return
    end
    unless receipt.current_mailbox?
      receipt.retire_if_mailbox_replaced!(
        expected_provider_account_id: provider_account_id,
        expected_generation: email_connection_generation
      )
      return
    end
    unless receipt.email_connection.inbound_ready?
      receipt.release_processing_enqueue!(job_id:)
      return
    end
    unless receipt.claim!(
      job_id:,
      provider_account_id:,
      email_connection_generation:
    )
      receipt.release_processing_enqueue!(job_id:)
      return
    end

    recorded_message = EmailMessageReceipts::Processor.call(receipt, job_id:)
    enqueue_reconsidered_thread_receipts(receipt, recorded_message)
    receipt.mark_post_processing_finalized! if receipt.reload.status_processed?
  rescue ProcessedFinalizationError
    raise
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => error
    retry_at = receipt && receipt.attempts < MAX_ATTEMPTS ? Time.current : nil
    receipt&.fail!(
      job_id:,
      error:,
      retry_at:,
      retry_job_id: retry_at ? job_id : nil
    )
    raise if retry_at
  rescue EmailConnection::Errors::CredentialChanged => error
    if receipt&.processing_owned_by?(job_id)
      receipt.fail!(job_id:, error:, retry_at: Time.current)
    else
      receipt&.release_processing_enqueue!(job_id:)
    end
    nil
  rescue EmailConnection::Errors::MessageNotFound
    receipt&.ignore!(job_id:, reason: :deleted_before_fetch)
  rescue EmailConnection::Errors::TemporaryProviderError => error
    retry_at = receipt && receipt.attempts < MAX_ATTEMPTS ? Time.current : nil
    receipt&.fail!(
      job_id:,
      error:,
      retry_at:,
      retry_job_id: retry_at ? job_id : nil
    )
    raise if retry_at
  rescue EmailConnection::Errors::PermanentProviderError => error
    receipt&.fail!(job_id:, error:, retry_at: nil)
  rescue EmailConnection::Errors::AuthenticationError => error
    receipt&.fail!(job_id:, error:, retry_at: 15.minutes.from_now)
    raise
  rescue EmailMessageReceipt::ClaimLost
    nil
  rescue StandardError => error
    receipt&.fail!(job_id:, error:, retry_at: nil)
    sanitized_error = UnexpectedProcessingError.new(error.class.name)
    sanitized_error.set_backtrace(error.backtrace)
    raise sanitized_error, cause: nil
  end

  def release_processing_enqueue_reservation
    receipt = EmailMessageReceipt.find_by(id: arguments.first)
    receipt&.release_processing_enqueue!(job_id:)
  end

  def release_post_processing_ownership
    receipt = EmailMessageReceipt.find_by(id: arguments.first)
    receipt&.release_post_processing_ownership!(job_id:)
  end

  def finalize_processed_receipt!(receipt, job_id:)
    message = receipt.conversation_message
    ConversationMessages::EmailRecorder.finalize_existing_delivery!(message)
    enqueue_reconsidered_thread_receipts(receipt, message)
    receipt.complete_post_processing!(job_id:)
  rescue StandardError => error
    receipt.reserve_post_processing_retry!(job_id:)
    sanitized = ProcessedFinalizationError.new(error.class.name)
    sanitized.set_backtrace(error.backtrace)
    raise sanitized, cause: nil
  end

  private
    def enqueue_reconsidered_thread_receipts(receipt, recorded_message)
      return unless recorded_message.is_a?(ConversationMessage)
      return unless recorded_message.trusted_matching_anchor?
      return if receipt.provider_thread_id.blank?

      EmailMessageReceipt.where(
        email_connection_id: receipt.email_connection_id,
        provider_account_id: receipt.provider_account_id,
        provider_thread_id: receipt.provider_thread_id,
        status: :pending
      ).where.not(id: receipt.id).find_each do |ignored_receipt|
        self.class.enqueue(ignored_receipt)
      rescue StandardError => error
        Rails.logger.error(
          "email.gmail_thread_receipt_enqueue_failed " \
            "receipt_id=#{ignored_receipt.id} error=#{error.class.name}"
        )
      end
    end
end

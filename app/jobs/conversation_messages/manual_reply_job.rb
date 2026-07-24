class ConversationMessages::ManualReplyJob < ApplicationJob
  queue_as :default

  retry_on EmailConnection::Errors::TemporaryDeliveryError,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.send(:record_exhausted_failure, error)
    end

  limits_concurrency(
    to: 1,
    key: ->(account_id, _message_id, thread_id) { "#{account_id}:#{thread_id}" },
    duration: 1.hour,
    on_conflict: :block
  )

  def perform(account_id, message_id, _thread_id)
    account = Account.find_by(id: account_id)
    return unless account

    message = account.conversation_messages.find_by(id: message_id)
    return unless message&.kind_manual_reply?
    if message.status_sent? || message.status_failed?
      ConversationMessages::ManualReplyOutcome.finalize!(message)
      return
    end
    return unless message.delivery_owned_by?(job_id)

    connection = current_connection_for(message)
    unless connection
      record_failure(message, "The connected Gmail account changed.")
      return
    end
    if message.email_connection_id.nil? &&
        !message.bind_delivery_mailbox!(connection:, job_id:)
      record_failure(message, "Reply delivery state changed.")
      return
    end

    mail_message = ConversationReplyMailer.reply(message).message
    message.apply_internet_message_id!(mail_message)
    return unless message.refresh_delivery_attempt!(
      job_id:,
      mail_message:,
      attempted_at: Time.current
    )
    return unless message.claim_provider_delivery!(job_id:)

    result = ConversationMessages::ProviderDelivery.call(
      account:,
      connection:,
      provider_account_id: message.provider_account_id,
      credential_generation: message.email_connection_generation,
      requested_provider_thread_id: message.requested_provider_thread_id,
      mail_message:,
      operation: "conversation_manual_reply_delivery",
      context: {
        account_id: account.id,
        conversation_id: message.conversation.canonical.id,
        conversation_message_id: message.id
      },
      conversation_message: message,
      delivery_job_id: job_id
    )
    record_result(message, result)
  end

  private
    def current_connection_for(message)
      connection = message.account.email_connection
      return unless connection&.gmail_ready?
      return unless connection.sender_matches?(message.from_address)
      return unless connection.provider_account_id == message.requested_provider_account_id

      connection
    end

    def record_result(message, result)
      if result.confirmed?
        recorded = message.mark_delivery_sent!(
          job_id:,
          sent_at: Time.current,
          provider_message_id: result.provider_message_id,
          provider_thread_id: result.provider_thread_id
        )
        return unless recorded || message.reload.status_sent?

        ConversationMessages::ManualReplyOutcome.finalize!(message)
      else
        recorded = message.mark_delivery_failed!(
          job_id:,
          failure_reason: safe_failure_reason(result),
          delivery_uncertain: result.unconfirmed?
        )
        return unless recorded || message.reload.status_failed?

        ConversationMessages::ManualReplyOutcome.finalize!(message)
      end
    end

    def record_failure(message, reason)
      recorded = message.mark_delivery_failed!(
        job_id:,
        failure_reason: reason,
        delivery_uncertain: message.provider_delivery_claimed?
      )
      return unless recorded || message.reload.status_failed?

      ConversationMessages::ManualReplyOutcome.finalize!(message)
    end

    def safe_failure_reason(result)
      result.unconfirmed? ?
        ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON :
        "Gmail could not send this reply."
    end

    def record_exhausted_failure(_error)
      account_id, message_id, = arguments
      account = Account.find_by(id: account_id)
      message = account&.conversation_messages&.find_by(id: message_id)
      return false unless message

      record_failure(message, "Gmail could not send this reply after retrying.")
    end
end

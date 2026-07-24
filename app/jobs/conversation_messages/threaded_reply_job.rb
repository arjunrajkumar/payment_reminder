class ConversationMessages::ThreadedReplyJob < ApplicationJob
  queue_as :default

  retry_on EmailConnection::Errors::TemporaryDeliveryError,
    wait: :polynomially_longer,
    attempts: 5 do |job, _error|
      job.send(:record_exhausted_failure)
    end

  limits_concurrency(
    to: 1,
    key: ->(account_id, _message_id, thread_id, *) { "#{account_id}:#{thread_id}" },
    group: "ConversationThreadedReply",
    duration: 1.hour,
    on_conflict: :block
  )

  def perform(account_id, message_id, _thread_id, scheduling_generation = nil)
    account = Account.find_by(id: account_id)
    message = account&.conversation_messages&.find_by(id: message_id)
    return unless message&.action_reply?
    if message.status_sent? || message.status_failed?
      ConversationMessages::ActionReplyOutcome.finalize!(message)
      return
    end
    return unless message.consume_reply_schedule!(
      generation: scheduling_generation,
      job_id:,
      at: Time.current
    )
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
      operation: "conversation_action_reply_delivery",
      context: {
        account_id: account.id,
        conversation_message_id: message.id,
        conversation_action_execution_id:
          message.conversation_action_execution_id
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
      return unless connection.provider_account_id ==
        message.requested_provider_account_id

      connection
    end

    def record_result(message, result)
      if result.confirmed?
        message.mark_delivery_sent!(
          job_id:,
          sent_at: Time.current,
          provider_message_id: result.provider_message_id,
          provider_thread_id: result.provider_thread_id
        )
      else
        message.mark_delivery_failed!(
          job_id:,
          failure_reason: result.unconfirmed? ?
            ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON :
            "Gmail could not send this reply.",
          delivery_uncertain: result.unconfirmed?
        )
      end
      ConversationMessages::ActionReplyOutcome.finalize!(message.reload)
    end

    def record_failure(message, reason)
      message.mark_delivery_failed!(
        job_id:,
        failure_reason: reason,
        delivery_uncertain: message.provider_delivery_claimed?
      )
      ConversationMessages::ActionReplyOutcome.finalize!(message.reload)
    end

    def record_exhausted_failure
      account_id, message_id, = arguments
      message = Account.find_by(id: account_id)
        &.conversation_messages&.find_by(id: message_id)
      record_failure(
        message,
        "Gmail could not send this reply after retrying."
      ) if message
    end
end

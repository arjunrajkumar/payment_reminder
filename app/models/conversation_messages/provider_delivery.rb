class ConversationMessages::ProviderDelivery
  UNCONFIRMED_FAILURE_REASON = "Email provider did not confirm delivery."

  Result = Data.define(
    :provider_message_id,
    :provider_thread_id,
    :failure_reason,
    :delivery_uncertain
  ) do
    def confirmed?
      provider_message_id.present?
    end

    def unconfirmed?
      delivery_uncertain
    end
  end

  def self.call(
    account:,
    connection:,
    provider_account_id:,
    credential_generation:,
    mail_message:,
    operation:,
    context:,
    conversation_message: nil,
    delivery_job_id: nil,
    requested_provider_thread_id: nil,
    &delivery
  )
    new(
      account:,
      connection:,
      provider_account_id:,
      credential_generation:,
      mail_message:,
      operation:,
      context:,
      conversation_message:,
      delivery_job_id:,
      requested_provider_thread_id:,
      delivery:
    ).call
  end

  def initialize(
    account:,
    connection:,
    provider_account_id:,
    credential_generation:,
    mail_message:,
    operation:,
    context:,
    conversation_message:,
    delivery_job_id:,
    requested_provider_thread_id:,
    delivery: nil
  )
    @account = account
    @connection = connection
    @provider_account_id = provider_account_id
    @credential_generation = credential_generation
    @mail_message = mail_message
    @operation = operation
    @context = context
    @conversation_message = conversation_message
    @delivery_job_id = delivery_job_id
    @requested_provider_thread_id = requested_provider_thread_id
    @delivery = delivery
  end

  def call
    confirmed_result(deliver)
  rescue EmailConnection::Errors::CredentialChanged
    release_retry_safe_claim(release_mailbox_binding: true)
    raise EmailConnection::Errors::TemporaryDeliveryError,
      "Email connection changed before delivery; retrying.",
      cause: nil
  rescue EmailConnection::Errors::TemporaryDeliveryError
    release_retry_safe_claim
    raise
  rescue EmailConnection::Errors::AmbiguousDeliveryError => error
    unconfirmed_result(error.message)
  rescue EmailConnection::Errors::AuthenticationError => error
    report_authentication_failure(error)
    failed_result(error.message)
  rescue StandardError => error
    failed_result(error.message)
  end

  private
    attr_reader :account,
      :connection,
      :provider_account_id,
      :credential_generation,
      :mail_message,
      :operation,
      :context,
      :conversation_message,
      :delivery_job_id,
      :requested_provider_thread_id,
      :delivery

    def deliver
      return delivery.call(mail_message) if delivery

      delivery_arguments = {
        account:,
        connection:,
        provider_account_id:,
        credential_generation:
      }
      if requested_provider_thread_id.present?
        delivery_arguments[:requested_provider_thread_id] = requested_provider_thread_id
      end
      EmailConnection::Delivery.new(**delivery_arguments).deliver(mail_message)
    end

    def confirmed_result(delivery_result)
      message_id = provider_message_id(delivery_result)
      return unconfirmed_result unless message_id

      Result.new(
        provider_message_id: message_id,
        provider_thread_id: provider_thread_id(delivery_result),
        failure_reason: nil,
        delivery_uncertain: false
      )
    end

    def failed_result(failure_reason)
      Result.new(
        provider_message_id: nil,
        provider_thread_id: nil,
        failure_reason:,
        delivery_uncertain: false
      )
    end

    def unconfirmed_result(failure_reason = UNCONFIRMED_FAILURE_REASON)
      Result.new(
        provider_message_id: nil,
        provider_thread_id: nil,
        failure_reason:,
        delivery_uncertain: true
      )
    end

    def provider_message_id(delivery_result)
      value = if delivery_result.respond_to?(:provider_message_id)
        delivery_result.provider_message_id
      elsif delivery_result.is_a?(String)
        delivery_result
      end
      normalize_provider_id(value)
    end

    def provider_thread_id(delivery_result)
      return unless delivery_result.respond_to?(:provider_thread_id)

      normalize_provider_id(delivery_result.provider_thread_id)
    end

    def normalize_provider_id(value)
      value.to_s.strip.presence
    end

    def release_retry_safe_claim(release_mailbox_binding: false)
      return unless conversation_message

      unless conversation_message.provider_delivery_claimed?
        if release_mailbox_binding
          conversation_message.release_delivery_mailbox_binding!(
            connection:,
            job_id: delivery_job_id,
            provider_account_id:,
            credential_generation:
          )
        end
        return
      end

      attributes = { job_id: delivery_job_id }
      if release_mailbox_binding
        attributes.merge!(
          connection:,
          provider_account_id:,
          credential_generation:
        )
      end
      conversation_message.relinquish_provider_delivery_claim!(**attributes)
    end

    def report_authentication_failure(error)
      Sentry.capture_exception(
        error,
        tags: {
          provider: connection.provider.to_s,
          operation:
        },
        extra: context
      )
    end
end

class InvoiceReminders::ManualSendJob < ApplicationJob
  queue_as :default

  retry_on EmailConnection::Errors::TemporaryDeliveryError,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.send(:record_exhausted_failure, error)
    end

  retry_on InvoiceReminders::InvoiceFreshnessCheck::Error,
    InvoiceSources::Xero::OauthClient::Error,
    InvoiceSources::Stripe::ApiClient::Error,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.send(:record_exhausted_failure, error)
      raise error
    end

  limits_concurrency(
    to: 1,
    key: ->(invoice_id) { invoice_id.to_s },
    duration: 1.hour,
    on_conflict: :block
  )

  def perform(invoice_id)
    invoice = Invoice.find_by(id: invoice_id)
    return unless invoice

    invoice = InvoiceReminders::InvoiceFreshnessCheck.call(invoice)
    reservation = InvoiceReminders::ManualDeliveryReservation.call(
      invoice:,
      delivery_job_id: job_id
    )
    unless reservation.reserved?
      cancel_owned_pending_delivery(invoice:, reason: reservation.reason)
      log_skip(invoice:, result: reservation)
      return
    end

    deliver(invoice:, reservation:)
  end

  private
    def deliver(invoice:, reservation:)
      unless reservation.message.claim_provider_delivery!(job_id:)
        log_skip(
          invoice:,
          result: InvoiceReminders::ManualDeliveryReservation::Result.new(
            message: nil,
            connection: nil,
            mail_message: nil,
            reason: "delivery_state_changed",
            context: {}
          )
        )
        return
      end

      delivery_result = ConversationMessages::ProviderDelivery.call(
        account: invoice.account,
        connection: reservation.connection,
        provider_account_id: reservation.message.provider_account_id,
        credential_generation: reservation.message.email_connection_generation,
        mail_message: reservation.mail_message,
        operation: "manual_invoice_reminder_delivery",
        context: {
          account_id: invoice.account_id,
          invoice_id: invoice.id,
          conversation_message_id: reservation.message.id
        },
        conversation_message: reservation.message,
        delivery_job_id: job_id
      )

      if delivery_result.confirmed?
        reservation.message.mark_delivery_sent!(
          job_id:,
          sent_at: Time.current,
          provider_message_id: delivery_result.provider_message_id,
          provider_thread_id: delivery_result.provider_thread_id
        )
      else
        reservation.message.mark_delivery_failed!(
          job_id:,
          failure_reason: delivery_result.failure_reason,
          delivery_uncertain: delivery_result.delivery_uncertain
        )
      end
    end

    def record_exhausted_failure(error)
      invoice = Invoice.find_by(id: arguments.first)
      return false unless invoice

      cancel_owned_pending_delivery(invoice:, reason: error.message)
    end

    def cancel_owned_pending_delivery(invoice:, reason:)
      message = invoice.conversation_messages
        .direction_outbound
        .kind_manual_reminder
        .status_pending
        .find_by(delivery_job_id: job_id)

      message&.mark_delivery_failed!(
        job_id:,
        failure_reason: "Manual reminder was not delivered (#{reason || "unknown_reason"}).",
        delivery_uncertain: message.provider_delivery_claimed?
      ) || false
    end

    def log_skip(invoice:, result:)
      Rails.logger.info(
        "invoice_reminder.manual_skipped " \
          "account_id=#{invoice.account_id} invoice_id=#{invoice.id} " \
          "reason=#{result.reason} context=#{result.context.inspect}"
      )
    end
end

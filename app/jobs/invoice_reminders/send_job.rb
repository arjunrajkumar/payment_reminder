class InvoiceReminders::SendJob < ApplicationJob
  queue_as :default

  retry_on EmailConnection::Errors::TemporaryDeliveryError,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.send(:record_exhausted_temporary_failure, error)
    end

  retry_on InvoiceReminders::InvoiceFreshnessCheck::Error,
    InvoiceSources::Xero::OauthClient::Error,
    InvoiceSources::Stripe::ApiClient::Error,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.send(:record_exhausted_pending_failure, error)
      raise error
    end

  limits_concurrency(
    to: 1,
    key: ->(invoice_id, *) { invoice_id.to_s },
    duration: 1.hour,
    on_conflict: :block
  )

  def perform(invoice_id, category, day_offset, _queued_tone)
    stage_key = "#{category}_#{day_offset}"
    invoice = find_invoice(invoice_id:, stage_key:)
    return unless invoice

    if delivered_reminder = invoice.invoice_reminders
        .includes(:conversation_message)
        .find_by(stage_key:)
      if delivered_reminder.status_sent?
        InvoiceReminders::DeliveryLog.skipped(
          invoice:,
          stage_key:,
          reason: "duplicate_stage"
        )
        notify_account_users(
          invoice:,
          reminder: delivered_reminder,
          terminal: delivered_reminder.terminal_stage?
        )
        return
      end
    end

    decision = InvoiceReminders::DeliveryPreflight.call(
      invoice:,
      category:,
      day_offset:,
      delivery_job_id: job_id
    )
    unless decision.deliverable?
      handle_skip(invoice:, stage_key:, result: decision)
      cancel_owned_pending_delivery(invoice:, stage_key:, reason: decision.reason)
      return
    end

    invoice = InvoiceReminders::InvoiceFreshnessCheck.call(invoice)
    reservation = InvoiceReminders::DeliveryReservation.call(
      invoice:,
      category:,
      day_offset:,
      delivery_job_id: job_id
    )
    unless reservation.reserved?
      handle_skip(invoice:, stage_key:, result: reservation)
      cancel_owned_pending_delivery(invoice:, stage_key:, reason: reservation.reason)
      return
    end

    deliver_reminder(invoice:, reservation:)
  end

  private
    def find_invoice(invoice_id:, stage_key:)
      invoice = Invoice.find_by(id: invoice_id)
      return invoice if invoice

      InvoiceReminders::DeliveryLog.missing_invoice(invoice_id:, stage_key:)
      nil
    end

    def handle_skip(invoice:, stage_key:, result:)
      InvoiceReminders::DeliveryLog.skipped(
        invoice:,
        stage_key: result.stage&.key || stage_key,
        reason: result.reason,
        context: result.context
      )
    end

    def deliver_reminder(invoice:, reservation:)
      stage = reservation.stage
      reminder = reservation.reminder
      terminal = reminder.terminal_stage?
      claim = InvoiceReminders::FinalDeliveryClaim.call(
        invoice:,
        reminder:,
        delivery_job_id: job_id
      )
      unless claim.claimed?
        InvoiceReminders::DeliveryLog.skipped(
          invoice:,
          stage_key: stage.key,
          reason: claim.reason,
          context: claim.context
        )
        return
      end

      delivery_result = deliver_email(
        invoice:,
        connection: reservation.connection,
        mail_message: reservation.mail_message,
        message: reminder.conversation_message
      )
      recorded = record_delivery_result(
        reminder:,
        delivery_result:
      )

      unless recorded
        InvoiceReminders::DeliveryLog.skipped(
          invoice:,
          stage_key: stage.key,
          reason: "delivery_state_changed"
        )
        return
      end

      InvoiceReminders::DeliveryLog.completed(
        invoice:,
        stage_key: stage.key,
        delivered: delivery_result.confirmed?
      )
      notify_account_users(invoice:, reminder:, terminal:) if delivery_result.confirmed?
    end

    def record_delivery_result(reminder:, delivery_result:)
      if delivery_result.confirmed?
        reminder.conversation_message.mark_delivery_sent!(
          job_id:,
          sent_at: Time.current,
          provider_message_id: delivery_result.provider_message_id,
          provider_thread_id: delivery_result.provider_thread_id
        )
      else
        reminder.conversation_message.mark_delivery_failed!(
          job_id:,
          failure_reason: delivery_result.failure_reason,
          delivery_uncertain: delivery_result.delivery_uncertain
        )
      end
    end

    def notify_account_users(invoice:, reminder:, terminal:)
      InvoiceReminders::Notifier.deliver_once(
        invoice:,
        reminder:,
        terminal:
      )
    end

    def deliver_email(invoice:, connection:, mail_message:, message:)
      ConversationMessages::ProviderDelivery.call(
        account: invoice.account,
        connection:,
        provider_account_id: message.provider_account_id,
        credential_generation: message.email_connection_generation,
        mail_message:,
        operation: "invoice_reminder_delivery",
        context: {
          account_id: invoice.account_id,
          invoice_id: invoice.id
        },
        conversation_message: message,
        delivery_job_id: job_id
      ) do
        send_email(
          invoice:,
          connection:,
          provider_account_id: message.provider_account_id,
          credential_generation: message.email_connection_generation,
          mail_message:
        )
      end
    end

    def send_email(
      invoice:,
      connection:,
      provider_account_id:,
      credential_generation:,
      mail_message:
    )
      EmailConnection::Delivery.new(
        account: invoice.account,
        connection:,
        provider_account_id:,
        credential_generation:
      ).deliver(mail_message)
    end

    def record_exhausted_temporary_failure(error)
      record_exhausted_pending_failure(error)
    end

    def record_exhausted_pending_failure(error)
      invoice_id, category, day_offset, = arguments
      invoice = Invoice.find_by(id: invoice_id)
      return false unless invoice

      stage_key = "#{category}_#{day_offset}"
      return false unless InvoiceReminder.fail_owned_delivery_for_stage!(
        invoice:,
        stage_key:,
        delivery_job_id: job_id,
        failure_reason: error.message
      )

      InvoiceReminders::DeliveryLog.completed(
        invoice:,
        stage_key:,
        delivered: false
      )
      true
    end

    def cancel_owned_pending_delivery(invoice:, stage_key:, reason:)
      InvoiceReminder.fail_owned_delivery_for_stage!(
        invoice:,
        stage_key:,
        delivery_job_id: job_id,
        failure_reason: "Reminder was no longer eligible (#{reason || "unknown_reason"})."
      )
    end
end

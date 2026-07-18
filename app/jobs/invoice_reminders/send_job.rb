class InvoiceReminders::SendJob < ApplicationJob
  queue_as :default

  retry_on OutboundEmailConnection::Errors::TemporaryDeliveryError,
    wait: :polynomially_longer,
    attempts: 5 do |job, error|
      job.send(:record_exhausted_temporary_failure, error)
    end

  limits_concurrency(
    to: 1,
    key: ->(invoice_id, category, day_offset, *) { "#{invoice_id}:#{category}_#{day_offset}" },
    duration: 1.hour,
    on_conflict: :block
  )

  def perform(invoice_id, category, day_offset, _queued_tone)
    stage_key = "#{category}_#{day_offset}"
    invoice = find_invoice(invoice_id:, stage_key:)
    return unless invoice
    connection = outbound_connection_for(invoice:, stage_key:)
    return unless connection
    return unless eligible_for_delivery?(invoice:, stage_key:)

    stage = current_stage_for(invoice:, category:, day_offset:)
    return unless stage
    return unless stage_not_delivered?(invoice:, stage:)
    return unless stage_due_today?(invoice:, stage:)
    return unless recipient_available?(invoice:, stage_key:)

    deliver_reminder(invoice:, stage:, connection:)
  end

  private
    def find_invoice(invoice_id:, stage_key:)
      invoice = Invoice.find_by(id: invoice_id)
      return invoice if invoice

      log_event(:warn, "invoice_reminder.skipped", reason: "missing_invoice", invoice_id:, stage_key:)
      nil
    end

    def eligible_for_delivery?(invoice:, stage_key:)
      unless invoice.account.automatic_invoice_reminders_enabled?
        log_skip(invoice:, stage_key:, reason: "disabled_account")
        return false
      end

      unless invoice.outstanding?
        log_skip(invoice:, stage_key:, reason: "not_outstanding")
        return false
      end

      if invoice.invoice_reminders.exists?(stage_key:)
        log_skip(invoice:, stage_key:, reason: "duplicate_stage")
        return false
      end

      true
    end

    def current_stage_for(invoice:, category:, day_offset:)
      payer_segment = invoice.customer.payer_segment
      stage = invoice.account.invoice_schedules.find_by(
        kind: payer_segment,
        category:,
        day_offset:
      )
      return stage if stage

      stage_key = "#{category}_#{day_offset}"
      log_skip(invoice:, stage_key:, reason: "stage_not_in_current_schedule", payer_segment:)
      nil
    end

    def stage_not_delivered?(invoice:, stage:)
      return true unless invoice.invoice_reminders.exists?(invoice_schedule: stage)

      log_skip(invoice:, stage_key: stage.key, reason: "duplicate_stage")
      false
    end

    def stage_due_today?(invoice:, stage:)
      return true if invoice.due_on == stage.invoice_due_on_for(reminder_on: Date.current)

      log_skip(invoice:, stage_key: stage.key, reason: "stage_not_due", due_on: invoice.due_on || "none")
      false
    end

    def recipient_available?(invoice:, stage_key:)
      return true if invoice.customer.reminder_email_addresses.any?

      log_skip(
        :warn,
        invoice:,
        stage_key:,
        reason: "missing_email",
        customer_id: invoice.customer_id
      )
      false
    end

    def outbound_connection_for(invoice:, stage_key:)
      account = invoice.account.reload
      connection = account.outbound_email_connection&.reload

      unless connection&.active? && connection.account_id == account.id
        log_skip(:warn, invoice:, stage_key:, reason: "missing_outbound_email_connection")
        return
      end

      unless connection.sender_matches?(account.invoice_reminder_from_email)
        log_skip(:warn, invoice:, stage_key:, reason: "sender_address_mismatch")
        return
      end

      connection
    end

    def deliver_reminder(invoice:, stage:, connection:)
      terminal = stage.category_overdue? && stage.terminal?
      @outbound_connection = connection
      email_sent, provider_message_id, failure_reason = send_email_result(invoice:, stage:)

      reminder = record_delivery(
        invoice:,
        stage:,
        email_sent:,
        provider_message_id:,
        failure_reason:
      )
      log_delivery(invoice:, stage:, email_sent:)
      notify_account_users(invoice:, reminder:, terminal:) if email_sent
    end

    def record_delivery(invoice:, stage:, email_sent:, provider_message_id: nil, failure_reason:)
      receipt_attributes = {
        account: invoice.account,
        category: stage.category,
        day_offset: stage.day_offset,
        stage_key: stage.key,
        status: email_sent ? :sent : :failed,
        tone: stage.tone.to_s,
        sent_at: email_sent ? Time.current : nil,
        provider_message_id: email_sent ? provider_message_id : nil,
        failure_reason:
      }

      invoice.invoice_reminders.create!(receipt_attributes.merge(invoice_schedule: stage))
    rescue ActiveRecord::InvalidForeignKey
      invoice.invoice_reminders.create!(receipt_attributes)
    end

    def log_delivery(invoice:, stage:, email_sent:)
      log_event(
        email_sent ? :info : :error,
        "invoice_reminder.delivery_#{email_sent ? "succeeded" : "failed"}",
        account_id: invoice.account_id,
        invoice_id: invoice.id,
        stage_key: stage.key
      )
    end

    def notify_account_users(invoice:, reminder:, terminal:)
      InvoiceReminders::Notifier.deliver(invoice:, reminder:, terminal:)
    end

    def send_email_result(invoice:, stage:)
      result = send_email(invoice:, stage:)
      [ result.present?, result.is_a?(String) ? result : nil, nil ]
    rescue OutboundEmailConnection::Errors::TemporaryDeliveryError
      raise
    rescue StandardError => error
      [ false, nil, error.message ]
    end

    def send_email(invoice:, stage:)
      message = InvoiceReminderMailer.reminder(invoice, stage).message
      OutboundEmailConnection::Delivery.new(
        account: invoice.account,
        connection: @outbound_connection
      ).deliver(message)
    end

    def record_exhausted_temporary_failure(error)
      invoice_id, category, day_offset, = arguments
      invoice = Invoice.find_by(id: invoice_id)
      return unless invoice

      stage = current_stage_for(invoice:, category:, day_offset:)
      return unless stage
      return if invoice.invoice_reminders.exists?(stage_key: stage.key)

      record_delivery(
        invoice:,
        stage:,
        email_sent: false,
        failure_reason: error.message
      )
      log_delivery(invoice:, stage:, email_sent: false)
    end

    def log_skip(level = :info, invoice:, stage_key:, reason:, **context)
      log_event(
        level,
        "invoice_reminder.skipped",
        reason:,
        account_id: invoice.account_id,
        invoice_id: invoice.id,
        **context,
        stage_key:
      )
    end

    def log_event(level, event, **context)
      details = context.map { |key, value| "#{key}=#{value}" }.join(" ")
      Rails.logger.public_send(level, "#{event} #{details}")
    end
end

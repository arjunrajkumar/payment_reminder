class InvoiceReminders::SendJob < ApplicationJob
  queue_as :default

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
    return unless eligible_for_delivery?(invoice:, stage_key:)

    stage = current_stage_for(invoice:, stage_key:)
    return unless stage
    return unless stage_due_today?(invoice:, stage:)
    return unless recipient_available?(invoice:, stage_key:)

    deliver_reminder(invoice:, stage:)
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

    def current_stage_for(invoice:, stage_key:)
      payer_segment = invoice.customer.payer_segment
      stage = InvoiceReminder::Policy.stage_for(payer_segment:, stage_key:)
      return stage if stage

      log_skip(invoice:, stage_key:, reason: "stage_not_in_current_policy", payer_segment:)
      nil
    end

    def stage_due_today?(invoice:, stage:)
      return true if invoice.due_on == stage.invoice_due_on_for(reminder_on: Date.current)

      log_skip(invoice:, stage_key: stage.key, reason: "stage_not_due", due_on: invoice.due_on || "none")
      false
    end

    def recipient_available?(invoice:, stage_key:)
      return true if invoice.customer.email.present?

      log_skip(
        :warn,
        invoice:,
        stage_key:,
        reason: "missing_email",
        customer_id: invoice.customer_id
      )
      false
    end

    def deliver_reminder(invoice:, stage:)
      email_sent, failure_reason = send_email_result(
        invoice:,
        stage_key: stage.key,
        tone: stage.tone.to_s
      )

      record_delivery(invoice:, stage:, email_sent:, failure_reason:)
      log_delivery(invoice:, stage:, email_sent:)
      log_notification_placeholders(stage:) if email_sent
    end

    def record_delivery(invoice:, stage:, email_sent:, failure_reason:)
      invoice.invoice_reminders.create!(
        account: invoice.account,
        category: stage.category,
        day_offset: stage.day_offset,
        stage_key: stage.key,
        status: email_sent ? :sent : :failed,
        tone: stage.tone.to_s,
        sent_at: email_sent ? Time.current : nil,
        failure_reason:
      )
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

    def log_notification_placeholders(stage:)
      Rails.logger.info "Create notifications"
      Rails.logger.info "Create final-stage escalation notification" if stage.tone == :final
    end

    def send_email_result(invoice:, stage_key:, tone:)
      [ send_email(invoice:, stage_key:, tone:), nil ]
    rescue StandardError => error
      [ false, error.message ]
    end

    def send_email(invoice:, stage_key:, tone:)
      true
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

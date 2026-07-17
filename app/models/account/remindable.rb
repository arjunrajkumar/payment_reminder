module Account::Remindable
  extend ActiveSupport::Concern

  def enqueue_invoice_reminders
    return unless automatic_invoice_reminders_enabled?

    invoice_schedules.find_each do |schedule|
      enqueue_reminders(schedule:)
    end
  end

  private
    def enqueue_reminders(schedule:)
      invoices_needing_reminder(schedule:).find_each do |invoice|
        InvoiceReminders::SendJob.perform_later(
          invoice.id,
          schedule.category.to_s,
          schedule.day_offset,
          schedule.tone.to_s
        )
      end
    end

    def invoices_needing_reminder(schedule:)
      invoices
        .outstanding
        .joins(customer: :customer_segment)
        .where(customer_segments: { payer_segment: schedule.kind })
        .where(due_on: schedule.invoice_due_on_for(reminder_on: Date.current))
        .where.not(
          id: InvoiceReminder.where(invoice_schedule: schedule).select(:invoice_id)
        )
        .where.not(
          id: InvoiceReminder.where(stage_key: schedule.key).select(:invoice_id)
        )
    end
end

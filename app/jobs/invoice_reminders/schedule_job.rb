class InvoiceReminders::ScheduleJob < ApplicationJob
  queue_as :default

  def perform
    InvoiceReminder::Policy::SCHEDULES.each do |payer_segment, stages|
      stages.each do |stage|
        enqueue_reminders(payer_segment:, stage:)
      end
    end
  end

  private
    def enqueue_reminders(payer_segment:, stage:)
      invoices_needing_reminder(payer_segment:, stage:).find_each do |invoice|
        InvoiceReminders::SendJob.perform_later(
          invoice.id,
          stage.category.to_s,
          stage.day_offset,
          stage.tone.to_s
        )
      end
    end

    def invoices_needing_reminder(payer_segment:, stage:)
      Invoice.outstanding
        .joins(customer: :customer_segment)
        .where(customer_segments: { payer_segment: })
        .where(due_on: stage.invoice_due_on_for(reminder_on: Date.current))
        .where.not(
          id: InvoiceReminder.where(stage_key: stage.key).select(:invoice_id)
        )
    end
end

module Invoice::Remindable
  extend ActiveSupport::Concern

  def next_reminder_stage
    return unless outstanding? && due_on.present?

    current_reminder = current_invoice_reminder
    return if current_reminder && !current_reminder.status_sent?

    InvoiceReminder::Policy.get_next_stage(
      customer_segment: customer.customer_segment,
      current_reminder:,
      due_on:
    )
  end

  def current_invoice_reminder
    invoice_reminders.order(scheduled_at: :desc, id: :desc).first
  end

  def current_invoice_reminder_date
    current_invoice_reminder&.scheduled_at&.to_date
  end

  def next_invoice_reminder_date
    next_reminder_stage&.date_for(due_on:)
  end

  def set_next_invoice_reminder(scheduled_at:)
    with_lock do
      stage = next_reminder_stage
      return unless stage

      invoice_reminders.create!(
        account:,
        category: stage.category,
        day_offset: stage.day_offset,
        stage_key: stage.key,
        scheduled_at:
      )
    end
  end
end

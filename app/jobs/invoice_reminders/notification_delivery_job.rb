class InvoiceReminders::NotificationDeliveryJob < ApplicationJob
  queue_as :default

  def perform(outcome_id)
    outcome = InvoiceReminderNotificationDelivery.find_by(id: outcome_id)
    return unless outcome

    InvoiceReminders::Notifier.deliver_outcome(
      outcome,
      schedule_retry: true,
      retry_job_id: job_id
    )
  end
end

class InvoiceReminders::ReconcileNotificationDeliveriesJob < ApplicationJob
  queue_as :default

  def perform
    initialize_unfinished_reminders
    reconcile_stale_claims
    release_stale_builds
    release_stale_retry_reservations
    schedule_pending_outcomes
    finalize_initialized_reminders
  end

  private
    def initialize_unfinished_reminders
      uninitialized_reminders.find_each do |reminder|
        InvoiceReminders::Notifier.deliver_once(
          invoice: reminder.invoice,
          reminder:,
          terminal: reminder.terminal_stage?
        )
      rescue StandardError => error
        log_reconciliation_failure(reminder, error)
      end
    end

    def finalize_initialized_reminders
      initialized_unfinalized_reminders.find_each do |reminder|
        InvoiceReminders::Notifier.finalize_audit!(reminder)
      rescue StandardError => error
        log_reconciliation_failure(reminder, error)
      end
    end

    def sent_reminders
      InvoiceReminder.joins(:conversation_message)
        .where(notifications_finalized_at: nil)
        .where(
          conversation_messages: {
            kind: ConversationMessage.kinds.fetch(:scheduled_reminder),
            status: ConversationMessage.statuses.fetch(:sent)
          }
        )
    end

    def uninitialized_reminders
      sent_reminders.where(notifications_initialized_at: nil)
    end

    def initialized_unfinalized_reminders
      sent_reminders.where.not(notifications_initialized_at: nil)
    end

    def reconcile_stale_claims
      cutoff = InvoiceReminderNotificationDelivery::STALE_AFTER.ago
      InvoiceReminderNotificationDelivery.status_delivering
        .where(delivery_started_at: ..cutoff)
        .find_each do |outcome|
          next unless outcome.adjudicate_stale_claim!(before: cutoff)

          InvoiceReminders::Notifier.finalize_audit!(
            outcome.invoice_reminder
          )
        end
    end

    def schedule_pending_outcomes
      due_unowned_outcomes.find_each do |outcome|
        if outcome.attempts >=
            InvoiceReminderNotificationDelivery::MAX_TRANSPORT_ATTEMPTS ||
            outcome.build_attempts >=
              InvoiceReminderNotificationDelivery::MAX_BUILD_ATTEMPTS
          exhaust(outcome)
        else
          enqueue(outcome)
        end
      end
    end

    def enqueue(outcome)
      InvoiceReminders::Notifier.schedule_retry(
        outcome,
        run_at: outcome.next_retry_at || Time.current
      )
    end

    def exhaust(outcome)
      error = StandardError.new("Notification delivery retries exhausted")
      reason = if outcome.build_attempts >=
          InvoiceReminderNotificationDelivery::MAX_BUILD_ATTEMPTS
        "build_attempts_exhausted"
      else
        "transport_attempts_exhausted"
      end
      return unless outcome.record_failed!(
        error:,
        reason:
      )

      InvoiceReminders::Notifier.finalize_audit!(outcome.invoice_reminder)
    end

    def release_stale_retry_reservations
      cutoff = InvoiceReminderNotificationDelivery::
        RETRY_RESERVATION_STALE_AFTER.ago
      stale_retry_reservations(before: cutoff).find_each do |outcome|
          outcome.release_stale_retry_reservation!(before: cutoff)
        end
    end

    def release_stale_builds
      cutoff = InvoiceReminderNotificationDelivery::BUILD_STALE_AFTER.ago
      InvoiceReminderNotificationDelivery.status_pending
        .where(build_started_at: ..cutoff)
        .where.not(build_token: nil)
        .find_each do |outcome|
          outcome.release_stale_build!(before: cutoff)
        end
    end

    def stale_retry_reservations(before:)
      InvoiceReminderNotificationDelivery.status_pending
        .where(retry_enqueued_at: ..before)
        .where.not(retry_job_id: nil)
    end

    def due_unowned_outcomes
      InvoiceReminderNotificationDelivery.status_pending
        .where(build_token: nil)
        .where(retry_job_id: nil)
        .where("next_retry_at IS NULL OR next_retry_at <= ?", Time.current)
    end

    def log_reconciliation_failure(reminder, error)
      Rails.logger.error(
        "invoice_reminder.notification_reconciliation_failed " \
          "reminder_id=#{reminder.id} error_class=#{error.class.name}"
      )
    end
end

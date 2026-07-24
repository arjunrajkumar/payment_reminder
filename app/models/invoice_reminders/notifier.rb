require "net/smtp"
require "openssl"

class InvoiceReminders::Notifier
  EVENTS = {
    reminder: "invoice_reminder",
    stopped: "invoice_reminder_stopped"
  }.freeze
  RETRY_SAFE_PRECONNECT_ERRORS = [
    SocketError,
    Net::OpenTimeout,
    Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Net::SMTPAuthenticationError
  ].freeze
  DEFINITE_SMTP_REJECTIONS = [
    Net::SMTPServerBusy,
    Net::SMTPSyntaxError,
    Net::SMTPFatalError
  ].freeze
  RETRY_SAFE_BEFORE_DATA_ERRORS = [
    Net::SMTPUnknownError,
    OpenSSL::SSL::SSLError,
    Net::ReadTimeout,
    Timeout::Error,
    EOFError,
    IOError,
    Errno::ECONNRESET,
    Errno::EPIPE,
    Errno::ETIMEDOUT
  ].freeze

  class << self
    def deliver_once(invoice:, reminder:, terminal: nil)
      deliver(invoice:, reminder:, terminal:)
    end

    def deliver(invoice:, reminder:, terminal: nil)
      new(invoice:, reminder:, terminal:).deliver
    end

    def deliver_outcome(outcome, schedule_retry:, retry_job_id: nil)
      reminder = outcome.invoice_reminder
      new(
        invoice: reminder.invoice,
        reminder:,
        terminal: reminder.terminal_at_delivery?
      ).send(
        :deliver_outcome,
        outcome,
        schedule_retry:,
        retry_job_id:
      )
    end

    def schedule_retry(outcome, run_at: nil)
      reminder = outcome.invoice_reminder
      new(
        invoice: reminder.invoice,
        reminder:,
        terminal: reminder.terminal_at_delivery?
      ).send(:schedule_retry, outcome, run_at:)
    end

    def finalize_audit!(reminder)
      new(
        invoice: reminder.invoice,
        reminder:,
        terminal: reminder.terminal_at_delivery?
      ).send(:finalize_audit!)
    end
  end

  def initialize(invoice:, reminder:, terminal: nil)
    @invoice = invoice
    @reminder = reminder
    @requested_terminal = terminal
  end

  def deliver
    initialize_outcomes!
    reminder.notification_deliveries.order(:id).find_each do |outcome|
      deliver_outcome(outcome, schedule_retry: true)
    end
    finalize_audit!
  end

  private
    attr_reader :invoice, :reminder, :requested_terminal

    def initialize_outcomes!
      reminder.with_lock do
        if reminder.terminal_at_delivery.nil?
          reminder.update!(terminal_at_delivery: requested_terminal == true)
        end
        next if reminder.notifications_initialized_at?

        intended_events.each do |event_name|
          subscribers_for(event_name).find_each do |user|
            reminder.notification_deliveries.create!(
              account: invoice.account,
              recipient_user: user,
              recipient_user_snapshot_id: user.id,
              recipient_email: user.identity.email_address,
              event_name:,
              status: :pending
            )
          end
        end
        reminder.update!(notifications_initialized_at: Time.current)
      end
    end

    def intended_events
      [ EVENTS.fetch(:reminder) ].tap do |events|
        events << EVENTS.fetch(:stopped) if reminder.terminal_at_delivery?
      end
    end

    def subscribers_for(event_name)
      invoice.account.users.active
        .where.not(verified_at: nil)
        .joins(:identity, :notification_subscriptions)
        .merge(
          NotificationSubscription.email_enabled.where(event: event_name)
        )
        .distinct
    end

    def deliver_outcome(outcome, schedule_retry:, retry_job_id: nil)
      outcome.reload
      return :terminal if outcome.status_delivered? ||
        outcome.status_uncertain? ||
        outcome.status_failed? ||
        outcome.status_canceled?
      return :busy if outcome.status_delivering?

      unless recipient_still_eligible?(outcome)
        outcome.record_canceled!(reason: "recipient_no_longer_eligible")
        finalize_audit!
        return :canceled
      end

      build_token = SecureRandom.uuid
      build_claim = outcome.claim_for_build!(
        build_token:,
        retry_job_id:,
        allow_unowned_retry: !schedule_retry
      )
      if build_claim == :failed
        finalize_audit!
        return :failed
      end
      return :busy unless build_claim == :claimed

      delivery = build_delivery(
        outcome,
        build_token:,
        schedule_retry:,
        retry_job_id:
      )
      return delivery unless delivery.respond_to?(:deliver_now)

      attempt_token = SecureRandom.uuid
      return :busy unless outcome.claim_for_delivery!(
        attempt_token:,
        build_token:,
        retry_job_id:,
        allow_unowned_retry: !schedule_retry
      )

      smtp_phase = nil
      begin
        InvoiceReminders::SmtpDeliveryPhase.track do |phase|
          smtp_phase = phase
          delivery.deliver_now
        end
      rescue StandardError => error
        return record_transport_failure(
          outcome,
          attempt_token:,
          error:,
          smtp_phase:,
          schedule_retry:
        )
      end

      if outcome.record_delivered!(attempt_token:)
        log_delivery(:info, "delivered", outcome:)
        finalize_audit!
        :delivered
      else
        :ownership_lost
      end
    end

    def build_delivery(
      outcome,
      build_token:,
      schedule_retry:,
      retry_job_id:
    )
      delivery = notification_for(outcome)
      message = delivery.message if delivery.respond_to?(:message)
      message.encoded if message&.respond_to?(:encoded)
      delivery
    rescue StandardError => error
      retry_at = retry_at_for(outcome)
      result = outcome.record_build_failure!(
        build_token:,
        error:,
        retry_at:
      )
      if result
        log_delivery(:error, "preclaim_failed", outcome:, error:)
        if result == :failed
          finalize_audit!
          return :failed
        end
        return schedule_retry(outcome, run_at: retry_at) if schedule_retry

        return :retry
      end
      :busy
    end

    def record_transport_failure(
      outcome,
      attempt_token:,
      error:,
      smtp_phase:,
      schedule_retry:
    )
      if smtp_phase&.accepted?
        if outcome.record_delivered!(attempt_token:)
          log_delivery(
            :info,
            "delivered_with_cleanup_error",
            outcome:,
            error:
          )
          finalize_audit!
          return :delivered
        end
      elsif retry_safe_transport_failure?(error, smtp_phase:)
        retry_at = retry_at_for(outcome)
        result = outcome.record_known_failure!(
          attempt_token:,
          error:,
          retry_at:
        )
        if result
          log_delivery(:error, "failed", outcome:, error:)
          if result == :failed
            finalize_audit!
            return :failed
          end
          return schedule_retry(outcome, run_at: retry_at) if schedule_retry

          return :retry
        end
      else
        recorded = outcome.record_uncertain!(attempt_token:, error:)
        if recorded
          log_delivery(:error, "unconfirmed", outcome:, error:)
          finalize_audit!
          return :uncertain
        end
      end
      :ownership_lost
    end

    def schedule_retry(outcome, run_at: nil)
      run_at ||= outcome.next_retry_at || retry_at_for(outcome)
      job = InvoiceReminders::NotificationDeliveryJob.new(outcome.id)
      return :busy unless outcome.reserve_retry!(
        job_id: job.job_id,
        run_at:
      )

      enqueued = job.enqueue(wait_until: run_at)
      unless enqueued
        raise(
          job.enqueue_error ||
            ActiveJob::EnqueueError.new(
              "Could not enqueue invoice reminder notification"
            )
        )
      end
      :retry_scheduled
    rescue StandardError => enqueue_error
      recorded = outcome.record_scheduling_failure!(
        job_id: job.job_id,
        error: enqueue_error
      )
      log_delivery(
        :error,
        "retry_enqueue_failed",
        outcome:,
        error: enqueue_error
      )
      finalize_audit! if recorded && outcome.reload.status_failed?
      :retry_enqueue_failed
    end

    def recipient_still_eligible?(outcome)
      user = outcome.recipient_user
      user&.account_id == outcome.account_id &&
        user.active? &&
        user.verified_at.present? &&
        user.identity&.email_address == outcome.recipient_email &&
        NotificationSubscription.email_enabled.exists?(
          user_id: user.id,
          event: outcome.event_name
        )
    end

    def notification_for(outcome)
      user = outcome.recipient_user
      if outcome.event_name == EVENTS.fetch(:stopped)
        InvoiceReminderNotificationMailer.manual_follow_up(
          user,
          invoice,
          reminder,
          recipient_email: outcome.recipient_email
        )
      else
        InvoiceReminderNotificationMailer.reminder_sent(
          user,
          invoice,
          reminder,
          terminal: reminder.terminal_at_delivery?,
          recipient_email: outcome.recipient_email
        )
      end
    end

    def retry_safe_transport_failure?(error, smtp_phase:)
      return true if DEFINITE_SMTP_REJECTIONS.any? do |error_class|
        error.is_a?(error_class)
      end
      return true if RETRY_SAFE_PRECONNECT_ERRORS.any? do |error_class|
        error.is_a?(error_class)
      end
      return false unless smtp_phase&.before_data?

      RETRY_SAFE_BEFORE_DATA_ERRORS.any? do |error_class|
        error.is_a?(error_class)
      end
    end

    def retry_at_for(outcome, at: Time.current)
      completed_attempts = [
        outcome.attempts,
        outcome.build_attempts,
        1
      ].max
      at + (completed_attempts**4 + 2).seconds
    end

    def finalize_audit!
      finalized = false
      reminder.with_lock do
        if reminder.notifications_finalized_at?
          finalized = true
          next
        end

        outcomes = reminder.notification_deliveries
        next if outcomes.where.not(
          status: %i[delivered uncertain failed canceled]
        ).exists?

        counts = outcomes.group(:status).count
        ConversationEvent.record_once!(
          conversation: reminder.conversation_message.conversation,
          conversation_message: reminder.conversation_message,
          kind: :invoice_reminder_notifications_finalized,
          actor_kind: :system,
          metadata: {
            "invoice_reminder_id" => reminder.id,
            "terminal" => reminder.terminal_at_delivery?,
            "delivered_count" => counts.fetch("delivered", 0),
            "uncertain_count" => counts.fetch("uncertain", 0),
            "failed_count" => counts.fetch("failed", 0),
            "canceled_count" => counts.fetch("canceled", 0)
          }
        )
        reminder.update!(notifications_finalized_at: Time.current)
        finalized = true
      end
      finalized
    end

    def log_delivery(level, outcome_name, outcome:, error: nil)
      context = {
        event: outcome.event_name,
        account_id: invoice.account_id,
        invoice_id: invoice.id,
        user_id: outcome.recipient_user_id,
        error_class: error&.class&.name
      }.compact
      details = context.map { |key, value| "#{key}=#{value}" }.join(" ")

      Rails.logger.public_send(
        level,
        "invoice_reminder.notification_#{outcome_name} #{details}"
      )
    end
end

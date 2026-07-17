class InvoiceReminders::Notifier
  def self.deliver(invoice:, reminder:, terminal:)
    new(invoice:, reminder:, terminal:).deliver
  end

  def initialize(invoice:, reminder:, terminal:)
    @invoice = invoice
    @reminder = reminder
    @terminal = terminal
  end

  def deliver
    deliver_event("invoice_reminder")
    deliver_event("invoice_reminder_stopped") if terminal
  end

  private
    attr_reader :invoice, :reminder, :terminal

    def deliver_event(event)
      subscribers_for(event).find_each do |user|
        begin
          notification_for(event, user).deliver_now
          log_delivery(:info, "delivered", event:, user:)
        rescue StandardError => error
          log_delivery(:error, "failed", event:, user:, error:)
        end
      end
    rescue StandardError => error
      log_delivery(:error, "failed", event:, error:)
    end

    def subscribers_for(event)
      invoice.account.users.active
        .joins(:identity, :notification_subscriptions)
        .merge(NotificationSubscription.email_enabled.where(event:))
        .distinct
    end

    def notification_for(event, user)
      if event == "invoice_reminder_stopped"
        InvoiceReminderNotificationMailer.manual_follow_up(user, invoice, reminder)
      else
        InvoiceReminderNotificationMailer.reminder_sent(user, invoice, reminder, terminal:)
      end
    end

    def log_delivery(level, outcome, event:, user: nil, error: nil)
      context = {
        event:,
        account_id: invoice.account_id,
        invoice_id: invoice.id,
        user_id: user&.id,
        error_class: error&.class&.name
      }.compact
      details = context.map { |key, value| "#{key}=#{value}" }.join(" ")

      Rails.logger.public_send(level, "invoice_reminder.notification_#{outcome} #{details}")
    end
end

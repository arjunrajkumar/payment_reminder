require "net/smtp"

class InvoiceReminders::SmtpDeliveryPhase
  STATE_KEY = :invoice_reminder_smtp_delivery_phase

  module NetSmtpInstrumentation
    private
      def do_start(...)
        InvoiceReminders::SmtpDeliveryPhase.mark_setup_started!
        super
      end

      def do_finish(...)
        InvoiceReminders::SmtpDeliveryPhase.mark_cleanup_started!
        super
      end

      def get_response(request_line)
        response = super
        if request_line == "DATA" && response.continue?
          InvoiceReminders::SmtpDeliveryPhase.mark_data_started!
        end
        response
      end

    public
    def mailfrom(...)
      InvoiceReminders::SmtpDeliveryPhase.mark_envelope_started!
      super
    end

    def rcptto(...)
      InvoiceReminders::SmtpDeliveryPhase.mark_envelope_started!
      super
    end

    def data(...)
      response = super
      InvoiceReminders::SmtpDeliveryPhase.mark_accepted!
      response
    end
  end

  class << self
    def track
      previous = current
      tracker = new
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = tracker
      yield tracker
    ensure
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = previous
    end

    def mark_setup_started!
      current&.mark_setup_started!
    end

    def mark_envelope_started!
      current&.mark_envelope_started!
    end

    def mark_envelope!
      mark_envelope_started!
    end

    def mark_data_started!
      current&.mark_data_started!
    end

    def mark_accepted!
      current&.mark_accepted!
    end

    def mark_cleanup_started!
      current&.mark_cleanup_started!
    end

    private
      def current
        ActiveSupport::IsolatedExecutionState[STATE_KEY]
      end
  end

  def initialize
    @phase = :unknown
    @acceptance_confirmed = false
  end

  attr_reader :phase

  def mark_setup_started!
    @phase = :setup unless accepted?
  end

  def mark_envelope_started!
    @phase = :envelope unless accepted?
  end

  def mark_envelope!
    mark_envelope_started!
  end

  def mark_data_started!
    @phase = :data_started unless accepted?
  end

  def mark_accepted!
    @acceptance_confirmed = true
    @phase = :accepted
  end

  def mark_cleanup_started!
    @phase = :cleanup if accepted?
  end

  def preconnect?
    phase == :setup
  end

  def before_data?
    %i[setup envelope].include?(phase)
  end

  def data_started?
    phase == :data_started
  end

  def accepted?
    @acceptance_confirmed
  end
end

unless Net::SMTP < InvoiceReminders::SmtpDeliveryPhase::NetSmtpInstrumentation
  Net::SMTP.prepend(
    InvoiceReminders::SmtpDeliveryPhase::NetSmtpInstrumentation
  )
end

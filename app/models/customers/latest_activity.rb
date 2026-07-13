class Customers::LatestActivity
  # The small, stable vocabulary used by the receivables table. Collection
  # state is deliberately separate: a customer can be awaiting payment while
  # their latest activity is still a reply.
  BADGES = {
    customer_replied: {
      label: "Customer replied",
      tone: "neutral",
      example_description: "Disputes the phase-two amount"
    },
    we_replied: {
      label: "We replied",
      tone: "neutral",
      example_description: "Sent the requested line-item breakdown"
    },
    reminder_sent: {
      label: "Reminder sent",
      tone: "neutral",
      example_description: "Sent a payment reminder to the billing contact"
    },
    reminder_opened: {
      label: "Reminder opened",
      tone: "neutral",
      example_description: "No response after three reminders"
    },
    scheduled: {
      label: "Scheduled",
      tone: "scheduled",
      example_description: "Reminder sends tomorrow if still unpaid"
    },
    payment_received: {
      label: "Payment received",
      tone: "paid",
      example_description: "USD 10,000 received today"
    },
    failed: {
      label: "Failed",
      tone: "failed",
      example_description: "Email bounced for the billing contact"
    },
    no_activity: {
      label: "No activity",
      tone: "neutral",
      example_description: "No message or payment activity yet"
    }
  }.freeze

  attr_reader :description

  def initialize(kind:, description: nil)
    @kind = kind.to_sym
    @description = description.presence || definition.fetch(:example_description)
  end

  private
    def definition
      @definition ||= BADGES.fetch(@kind)
    end
end

module CustomersHelper
  def customer_invoice_date(date)
    date ? I18n.l(date, format: "%b %-d, %Y") : "—"
  end

  def customer_invoice_due_context(invoice, as_of: Date.current)
    return "No due date" unless invoice&.due_on

    difference = (invoice.due_on - as_of).to_i
    return "Due today" if difference.zero?
    return "Due in #{pluralize(difference, "day")}" if difference.positive?

    "#{pluralize(difference.abs, "day")} overdue"
  end

  def customer_invoice_timing_label(event)
    days = event.fetch(:delay)

    if event.fetch(:paid)
      return "Date unavailable" unless days
      return "On due date" if days.zero?

      return "#{pluralize(days.abs, "day")} #{days.positive? ? "late" : "early"}"
    end

    return "Due today" if days.zero?
    return "#{pluralize(days, "day")} overdue" if days.positive?

    "Due in #{pluralize(days.abs, "day")}"
  end

  def customer_invoice_timing_tone(event)
    return "slate" unless event.fetch(:delay)
    return event.fetch(:delay).positive? ? "red-open" : "slate" unless event.fetch(:paid)
    return "green" if event.fetch(:delay) <= 0
    return "amber" if event.fetch(:delay) <= 7

    "red"
  end
end

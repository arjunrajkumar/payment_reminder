module CustomersHelper
  CUSTOMER_INVOICE_STATUSES = {
    overdue: { label: "Overdue", tone: "overdue" },
    outstanding: { label: "Outstanding", tone: "outstanding" },
    uncollectible: { label: "Uncollectible", tone: "uncollectible" },
    open: { label: "Open", tone: "open" },
    paid: { label: "Paid", tone: "paid" }
  }.freeze

  def customer_invoice_status(customer)
    CUSTOMER_INVOICE_STATUSES.fetch(customer_invoice_status_key(customer))
  end

  def customer_payer_profile(customer)
    Customers::PayerProfile.new(customer).to_h
  end

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
    return "Uncollectible" if event.fetch(:uncollectible)
    return "No balance due" if event.fetch(:no_balance_due)

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
    return "slate" if event.fetch(:uncollectible) || event.fetch(:no_balance_due)
    return "slate" unless event.fetch(:delay)
    return event.fetch(:delay).positive? ? "red-open" : "slate" unless event.fetch(:paid)
    return "green" if event.fetch(:delay) <= 0
    return "amber" if event.fetch(:delay) <= 7

    "red"
  end

  private
    def customer_invoice_status_key(customer)
      return :overdue if customer.overdue_invoices.any?
      return :outstanding if customer.outstanding_invoices.any?
      return :uncollectible if customer.uncollectible_invoices.any?
      return :open if customer.open_invoices.any?

      :paid
    end
end

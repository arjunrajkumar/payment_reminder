module InvoicesHelper
  INVOICE_STATUS_TONES = {
    pending: "in-progress",
    open: "in-progress",
    paid: "paid",
    uncollectible: "unpaid",
    void: "in-progress",
    unknown: "needs-attention"
  }.freeze

  def invoice_identifier(invoice)
    invoice.number.presence || invoice.external_id
  end

  def invoice_amount_payable(invoice)
    amount = invoice.amount_due.to_d
    currency = invoice.currency.presence&.upcase || "USD"
    precision = amount.frac.zero? ? 0 : 2

    number_to_currency(amount, unit: "#{currency} ", format: "%u%n", precision: precision)
  end

  def invoice_due_timing(invoice, as_of: Date.current)
    return unless invoice.due_on
    return unless invoice.amount_due.to_d.positive?
    return unless invoice.status_open? || invoice.status_pending?

    days_until_due = (invoice.due_on - as_of).to_i

    if days_until_due.negative?
      pluralize(days_until_due.abs, "day") + " overdue"
    elsif days_until_due.zero?
      "due today"
    else
      "due in " + pluralize(days_until_due, "day")
    end
  end

  def invoice_status_tone(invoice, as_of: Date.current)
    return "needs-attention" if invoice.overdue?(as_of: as_of)

    INVOICE_STATUS_TONES.fetch(invoice.status.to_sym)
  end
end

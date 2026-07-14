class Receivables::Dashboard
  attr_reader :as_of

  def initialize(invoices, as_of: Date.current)
    @invoices = invoices
    @as_of = as_of
  end

  def issued_invoices
    @invoices
  end

  def outstanding_invoices
    @outstanding_invoices ||= issued_invoices.select(&:outstanding?)
  end

  def open_invoices
    @open_invoices ||= issued_invoices.select(&:open?)
  end

  def overdue_invoices
    @overdue_invoices ||= outstanding_invoices
      .select { |invoice| invoice.overdue?(as_of: as_of) }
      .sort_by { |invoice| [ invoice.due_on, invoice.number.to_s ] }
  end

  def paid_invoices
    @paid_invoices ||= issued_invoices.select(&:paid?)
  end

  def uncollectible_invoices
    @uncollectible_invoices ||= issued_invoices.select(&:uncollectible?)
  end

  def outstanding_totals
    totals_for(outstanding_invoices, &:amount_due)
  end

  def uncollectible_totals
    totals_for(uncollectible_invoices, &:amount_due)
  end

  private
    def totals_for(invoices)
      invoices.each_with_object(Hash.new(0.to_d)) do |invoice, totals|
        totals[invoice.currency.presence || "Unspecified"] += yield(invoice).to_d
      end
    end
end

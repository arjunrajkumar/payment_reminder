module Customer::Invoicing
  extend ActiveSupport::Concern

  included do
    has_many :issued_invoices, -> { issued.recent }, class_name: "Invoice"

    scope :with_issued_invoices, -> { joins(:invoices).merge(Invoice.issued).distinct }
  end

  def as_of
    @as_of ||= Date.current
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

  def next_expected_invoice
    outstanding_invoices.min_by { |invoice| invoice.due_on || Date.new(9999, 12, 31) }
  end

  def oldest_overdue_days
    overdue_invoices.filter_map do |invoice|
      (as_of - invoice.due_on).to_i if invoice.due_on
    end.max
  end

  private
    def totals_for(invoices)
      invoices.each_with_object(Hash.new(0.to_d)) do |invoice, totals|
        totals[invoice.currency.presence || "Unspecified"] += yield(invoice).to_d
      end
    end
end

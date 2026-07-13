class Receivables::Dashboard
  EXCLUDED_STATUSES = %w[DRAFT SUBMITTED DELETED VOIDED VOID].freeze

  AGING_BUCKETS = [
    { key: :current, label: "Current", test_id: "current" },
    { key: :one_to_thirty, label: "1-30 days", test_id: "1-30" },
    { key: :thirty_one_to_sixty, label: "31-60 days", test_id: "31-60" },
    { key: :sixty_one_to_ninety, label: "61-90 days", test_id: "61-90" },
    { key: :ninety_plus, label: "Over 90 days", test_id: "90-plus" }
  ].freeze

  attr_reader :as_of

  def initialize(invoices, as_of: Date.current)
    @invoices = invoices.select { |invoice| issued_sales_invoice?(invoice) }
    @as_of = as_of
  end

  def issued_invoices
    @invoices
  end

  def outstanding_invoices
    @outstanding_invoices ||= issued_invoices.select { |invoice| outstanding?(invoice) }
  end

  def overdue_invoices
    @overdue_invoices ||= outstanding_invoices
      .select { |invoice| overdue?(invoice) }
      .sort_by { |invoice| [ invoice.due_on, invoice.number.to_s ] }
  end

  def paid_invoices
    @paid_invoices ||= issued_invoices.select(&:paid?)
  end

  def outstanding_totals
    totals_for(outstanding_invoices, &:amount_due)
  end

  def aging_buckets
    AGING_BUCKETS.map do |bucket|
      bucket_invoices = outstanding_invoices.select do |invoice|
        aging_bucket_for(invoice) == bucket.fetch(:key)
      end

      bucket.merge(totals: totals_for(bucket_invoices, &:amount_due))
    end
  end

  def older_than_thirty_totals
    totals_for(
      outstanding_invoices.select do |invoice|
        overdue?(invoice) && (as_of - invoice.due_on).to_i > 30
      end,
      &:amount_due
    )
  end

  def aging_series
    @aging_series ||= outstanding_totals.keys.sort.map do |currency|
      buckets = aging_buckets
      amounts = buckets.map { |bucket| bucket.fetch(:totals).fetch(currency, 0.to_d) }
      total = amounts.sum

      {
        currency: currency,
        buckets: buckets.zip(amounts).map do |bucket, amount|
          bucket.slice(:key, :label, :test_id).merge(
            amount: amount,
            percentage: percentage_of_total(amount, total)
          )
        end
      }
    end
  end

  private
    def issued_sales_invoice?(invoice)
      !excluded_status?(invoice) && sales_invoice?(invoice)
    end

    def sales_invoice?(invoice)
      !invoice.invoice_source.xero? || invoice.invoice_type.to_s.casecmp?("ACCREC")
    end

    def excluded_status?(invoice)
      invoice.status.to_s.upcase.in?(EXCLUDED_STATUSES)
    end

    def outstanding?(invoice)
      !invoice.paid? && invoice.amount_due.to_d.positive?
    end

    def overdue?(invoice)
      invoice.due_on.present? && invoice.due_on < as_of
    end

    def aging_bucket_for(invoice)
      return :current unless overdue?(invoice)

      case (as_of - invoice.due_on).to_i
      when 1..30 then :one_to_thirty
      when 31..60 then :thirty_one_to_sixty
      when 61..90 then :sixty_one_to_ninety
      else :ninety_plus
      end
    end

    def totals_for(invoices)
      invoices.each_with_object(Hash.new(0.to_d)) do |invoice, totals|
        totals[invoice.currency.presence || "Unspecified"] += yield(invoice).to_d
      end
    end

    def percentage_of_total(amount, total)
      return 0.0 unless total.positive?

      ((amount / total) * 100).to_f.round(1)
    end
end

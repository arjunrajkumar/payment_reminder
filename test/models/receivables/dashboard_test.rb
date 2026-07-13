require "test_helper"

class Receivables::DashboardTest < ActiveSupport::TestCase
  test "assigns exact aging boundaries to non-overlapping labels" do
    as_of = Date.new(2026, 7, 11)
    dashboard = Receivables::Dashboard.new(
      [
        invoice_due_on(as_of),
        invoice_due_on(as_of - 30.days),
        invoice_due_on(as_of - 31.days),
        invoice_due_on(as_of - 60.days),
        invoice_due_on(as_of - 61.days),
        invoice_due_on(as_of - 90.days),
        invoice_due_on(as_of - 91.days)
      ],
      as_of: as_of
    )

    buckets = dashboard.aging_buckets

    assert_equal [ "Current", "1-30 days", "31-60 days", "61-90 days", "Over 90 days" ], buckets.map { |bucket| bucket.fetch(:label) }
    assert_equal [ 1, 1, 2, 2, 1 ], buckets.map { |bucket| bucket.fetch(:totals).fetch("INR") }
  end

  test "keeps paid invoices visible without adding them to outstanding totals" do
    outstanding = invoice_due_on(Date.new(2026, 7, 20), amount_due: 100)
    paid = invoice_due_on(
      Date.new(2026, 7, 1),
      status: "PAID",
      amount_due: 0,
      amount_paid: 75,
      total: 75,
      paid_on: Date.new(2026, 7, 10)
    )
    paid_last_month = invoice_due_on(
      Date.new(2026, 6, 1),
      status: "PAID",
      amount_due: 0,
      amount_paid: 25,
      total: 25,
      paid_on: Date.new(2026, 6, 20)
    )
    draft = invoice_due_on(Date.new(2026, 7, 20), status: "DRAFT", amount_due: 50)

    dashboard = Receivables::Dashboard.new([ outstanding, paid, paid_last_month, draft ], as_of: Date.new(2026, 7, 11))

    assert_equal [ outstanding ], dashboard.outstanding_invoices
    assert_equal [ paid, paid_last_month ], dashboard.paid_invoices
    assert_equal({ "INR" => 100.to_d }, dashboard.outstanding_totals)
    assert_not_includes dashboard.issued_invoices, draft
  end

  test "builds aging chart series independently for each currency" do
    as_of = Date.new(2026, 7, 11)
    dashboard = Receivables::Dashboard.new(
      [
        invoice_due_on(as_of + 1.day, amount_due: 100),
        invoice_due_on(as_of - 10.days, amount_due: 50),
        invoice_due_on(as_of - 45.days, amount_due: 25, currency: "USD")
      ],
      as_of: as_of
    )

    inr, usd = dashboard.aging_series

    assert_equal "INR", inr.fetch(:currency)
    assert_equal [ 100.to_d, 50.to_d, 0.to_d, 0.to_d, 0.to_d ], inr.fetch(:buckets).map { |bucket| bucket.fetch(:amount) }
    assert_equal [ 66.7, 33.3, 0.0, 0.0, 0.0 ], inr.fetch(:buckets).map { |bucket| bucket.fetch(:percentage) }
    assert_equal "USD", usd.fetch(:currency)
    assert_equal [ 0.to_d, 0.to_d, 25.to_d, 0.to_d, 0.to_d ], usd.fetch(:buckets).map { |bucket| bucket.fetch(:amount) }
  end

  test "orders overdue invoices and totals balances older than thirty days" do
    as_of = Date.new(2026, 7, 11)
    current = invoice_due_on(as_of + 1.day, amount_due: 100)
    recent = invoice_due_on(as_of - 10.days, amount_due: 50)
    older = invoice_due_on(as_of - 45.days, amount_due: 25)
    dashboard = Receivables::Dashboard.new([ current, recent, older ], as_of: as_of)

    assert_equal [ older, recent ], dashboard.overdue_invoices
    assert_equal({ "INR" => 25.to_d }, dashboard.older_than_thirty_totals)
  end

  private
    def invoice_due_on(due_on, status: "AUTHORISED", amount_due: 1, amount_paid: 0, total: nil, paid_on: nil, currency: "INR")
      Invoice.new(
        invoice_source: invoice_sources(:xero),
        invoice_type: "ACCREC",
        status: status,
        currency: currency,
        amount_due: amount_due,
        amount_paid: amount_paid,
        total: total || amount_due,
        due_on: due_on,
        paid_on: paid_on
      )
    end
end

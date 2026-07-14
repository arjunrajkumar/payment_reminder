require "test_helper"

class Receivables::DashboardTest < ActiveSupport::TestCase
  test "keeps paid invoices visible without adding them to outstanding totals" do
    outstanding = invoice_due_on(Date.new(2026, 7, 20), amount_due: 100)
    paid = invoice_due_on(
      Date.new(2026, 7, 1),
      status: "paid",
      amount_due: 0,
      amount_paid: 75,
      total: 75,
      paid_on: Date.new(2026, 7, 10)
    )
    paid_last_month = invoice_due_on(
      Date.new(2026, 6, 1),
      status: "paid",
      amount_due: 0,
      amount_paid: 25,
      total: 25,
      paid_on: Date.new(2026, 6, 20)
    )
    dashboard = Receivables::Dashboard.new([ outstanding, paid, paid_last_month ], as_of: Date.new(2026, 7, 11))

    assert_equal [ outstanding ], dashboard.outstanding_invoices
    assert_equal [ paid, paid_last_month ], dashboard.paid_invoices
    assert_equal({ "INR" => 100.to_d }, dashboard.outstanding_totals)
  end

  test "keeps uncollectible invoices separate from collectible and paid invoices" do
    as_of = Date.new(2026, 7, 11)
    outstanding = invoice_due_on(as_of - 5.days, amount_due: 100)
    uncollectible = invoice_due_on(as_of - 30.days, status: "uncollectible", amount_due: 75)
    dashboard = Receivables::Dashboard.new([ outstanding, uncollectible ], as_of: as_of)

    assert_equal [ outstanding ], dashboard.outstanding_invoices
    assert_equal [ outstanding ], dashboard.overdue_invoices
    assert_empty dashboard.paid_invoices
    assert_equal [ uncollectible ], dashboard.uncollectible_invoices
    assert_equal({ "INR" => 75.to_d }, dashboard.uncollectible_totals)
  end

  test "keeps open invoices without a remaining balance separate from paid invoices" do
    open_without_balance = invoice_due_on(Date.new(2026, 7, 20), amount_due: 0)
    dashboard = Receivables::Dashboard.new([ open_without_balance ], as_of: Date.new(2026, 7, 11))

    assert_equal [ open_without_balance ], dashboard.open_invoices
    assert_empty dashboard.outstanding_invoices
    assert_empty dashboard.paid_invoices
  end

  test "orders overdue invoices by due date" do
    as_of = Date.new(2026, 7, 11)
    current = invoice_due_on(as_of + 1.day, amount_due: 100)
    recent = invoice_due_on(as_of - 10.days, amount_due: 50)
    older = invoice_due_on(as_of - 45.days, amount_due: 25)
    dashboard = Receivables::Dashboard.new([ current, recent, older ], as_of: as_of)

    assert_equal [ older, recent ], dashboard.overdue_invoices
  end

  private
    def invoice_due_on(due_on, status: "open", amount_due: 1, amount_paid: 0, total: nil, paid_on: nil, currency: "INR")
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

require "test_helper"

class Customer::InvoicingTest < ActiveSupport::TestCase
  setup do
    @source = invoice_sources(:xero)
    @customer = @source.customers.create!(
      account: @source.account,
      external_id: SecureRandom.uuid,
      name: "Invoicing Customer"
    )
  end

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

    travel_to Time.zone.local(2026, 7, 11, 12) do
      assert_equal [ outstanding ], @customer.outstanding_invoices
      assert_equal [ paid, paid_last_month ], @customer.paid_invoices
      assert_equal({ "INR" => 100.to_d }, @customer.outstanding_totals)
    end
  end

  test "keeps uncollectible invoices separate from collectible and paid invoices" do
    as_of = Date.new(2026, 7, 11)
    outstanding = invoice_due_on(as_of - 5.days, amount_due: 100)
    uncollectible = invoice_due_on(as_of - 30.days, status: "uncollectible", amount_due: 75)

    travel_to Time.zone.local(2026, 7, 11, 12) do
      assert_equal [ outstanding ], @customer.outstanding_invoices
      assert_equal [ outstanding ], @customer.overdue_invoices
      assert_empty @customer.paid_invoices
      assert_equal [ uncollectible ], @customer.uncollectible_invoices
      assert_equal({ "INR" => 75.to_d }, @customer.uncollectible_totals)
    end
  end

  test "keeps open invoices without a remaining balance separate from paid invoices" do
    open_without_balance = invoice_due_on(Date.new(2026, 7, 20), amount_due: 0)

    travel_to Time.zone.local(2026, 7, 11, 12) do
      assert_equal [ open_without_balance ], @customer.open_invoices
      assert_empty @customer.outstanding_invoices
      assert_empty @customer.paid_invoices
    end
  end

  test "orders overdue invoices by due date" do
    as_of = Date.new(2026, 7, 11)
    invoice_due_on(as_of + 1.day, amount_due: 100)
    recent = invoice_due_on(as_of - 10.days, amount_due: 50)
    older = invoice_due_on(as_of - 45.days, amount_due: 25)

    travel_to Time.zone.local(2026, 7, 11, 12) do
      assert_equal [ older, recent ], @customer.overdue_invoices
    end
  end

  private
    def invoice_due_on(due_on, status: "open", amount_due: 1, amount_paid: 0, total: nil, paid_on: nil, currency: "INR")
      @customer.invoices.create!(
        account: @customer.account,
        invoice_source: @source,
        external_id: SecureRandom.uuid,
        number: "INV-#{SecureRandom.hex(4)}",
        invoice_type: "ACCREC",
        provider_status: status,
        status: status,
        currency: currency,
        amount_due: amount_due,
        amount_paid: amount_paid,
        total: total || amount_due,
        issued_on: due_on - 30.days,
        due_on: due_on,
        paid_on: paid_on,
        contact_external_id: @customer.external_id,
        contact_name: @customer.name,
        synced_at: Time.current
      )
    end
end

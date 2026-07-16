require "test_helper"

class InvoicesHelperTest < ActionView::TestCase
  include InvoicesHelper

  test "uses the provider invoice number with an external id fallback" do
    assert_equal "INV-001", invoice_identifier(Invoice.new(number: "INV-001", external_id: "external-1"))
    assert_equal "external-1", invoice_identifier(Invoice.new(number: nil, external_id: "external-1"))
  end

  test "formats the payable amount with its currency" do
    assert_equal "USD 7,250", invoice_amount_payable(Invoice.new(currency: "USD", amount_due: 7_250))
    assert_equal "EUR 125.50", invoice_amount_payable(Invoice.new(currency: "eur", amount_due: 125.50))
  end

  test "does not invent an amount or currency when financial data is missing" do
    assert_equal "Amount unavailable", invoice_amount_payable(Invoice.new(currency: nil, amount_due: nil))
    assert_equal "Amount unavailable", invoice_amount_payable(Invoice.new(currency: "USD", amount_due: nil))
    assert_equal "Amount unavailable", invoice_amount_payable(Invoice.new(currency: nil, amount_due: 125))
  end

  test "describes when an outstanding invoice is due" do
    as_of = Date.new(2026, 7, 15)

    assert_equal "4 days overdue", invoice_due_timing(Invoice.new(status: "open", amount_due: 100, due_on: as_of - 4.days), as_of: as_of)
    assert_equal "1 day overdue", invoice_due_timing(Invoice.new(status: "open", amount_due: 100, due_on: as_of - 1.day), as_of: as_of)
    assert_equal "due today", invoice_due_timing(Invoice.new(status: "open", amount_due: 100, due_on: as_of), as_of: as_of)
    assert_equal "due in 1 day", invoice_due_timing(Invoice.new(status: "open", amount_due: 100, due_on: as_of + 1.day), as_of: as_of)
    assert_nil invoice_due_timing(Invoice.new(status: "pending", amount_due: 100, due_on: as_of + 7.days), as_of: as_of)
    assert_nil invoice_due_timing(Invoice.new(status: "pending", amount_due: 100, due_on: as_of - 4.days), as_of: as_of)
    assert_nil invoice_due_timing(Invoice.new(status: "paid", amount_due: 0, due_on: as_of - 4.days), as_of: as_of)
    assert_nil invoice_due_timing(Invoice.new(status: "open", amount_due: 100, due_on: nil), as_of: as_of)
  end

  test "labels the effective invoice status" do
    as_of = Date.new(2026, 7, 15)

    assert_equal "Overdue", invoice_status_label(Invoice.new(status: "open", amount_due: 100, due_on: as_of - 1.day), as_of: as_of)
    assert_equal "Outstanding", invoice_status_label(Invoice.new(status: "open", amount_due: 100, due_on: as_of + 1.day), as_of: as_of)
    assert_equal "Open", invoice_status_label(Invoice.new(status: "open", amount_due: 0, due_on: as_of + 1.day), as_of: as_of)
    assert_equal "Paid", invoice_status_label(Invoice.new(status: "paid", amount_due: 0, due_on: as_of - 1.day), as_of: as_of)
  end

  test "uses the effective invoice status tone" do
    as_of = Date.new(2026, 7, 15)

    assert_equal "overdue", invoice_status_tone(Invoice.new(status: "open", amount_due: 100, due_on: as_of - 1.day), as_of: as_of)
    assert_equal "outstanding", invoice_status_tone(Invoice.new(status: "open", amount_due: 100, due_on: as_of + 1.day), as_of: as_of)
    assert_equal "open", invoice_status_tone(Invoice.new(status: "open", amount_due: 0, due_on: as_of + 1.day), as_of: as_of)
    assert_equal "uncollectible", invoice_status_tone(Invoice.new(status: "uncollectible"), as_of: as_of)
    assert_equal "paid", invoice_status_tone(Invoice.new(status: "paid"), as_of: as_of)
    assert_equal "pending", invoice_status_tone(Invoice.new(status: "pending"), as_of: as_of)
    assert_equal "void", invoice_status_tone(Invoice.new(status: "void"), as_of: as_of)
    assert_equal "unknown", invoice_status_tone(Invoice.new(status: "unknown"), as_of: as_of)
  end
end

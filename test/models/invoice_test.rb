require "test_helper"

class InvoiceTest < ActiveSupport::TestCase
  test "belongs to an account and invoice source" do
    invoice = invoices(:xero_invoice)

    assert_equal accounts(:paid_jar), invoice.account
    assert_equal invoice_sources(:xero), invoice.invoice_source
  end

  test "requires an external id" do
    invoice = invoice_sources(:xero).invoices.build(account: accounts(:paid_jar))

    assert_not invoice.valid?
    assert_includes invoice.errors[:external_id], "can't be blank"
  end

  test "does not allow the same external id twice for a source" do
    invoice = invoice_sources(:xero).invoices.build(
      account: accounts(:paid_jar),
      external_id: invoices(:xero_invoice).external_id
    )

    assert_not invoice.valid?
    assert_includes invoice.errors[:external_id], "has already been taken"
  end

  test "identifies paid invoices from either provider status or settled amounts" do
    assert_predicate Invoice.new(status: "PAID", amount_due: 100, amount_paid: 0), :paid?
    assert_predicate Invoice.new(status: "AUTHORISED", amount_due: 0, amount_paid: 100), :paid?
    assert_not_predicate Invoice.new(status: "AUTHORISED", amount_due: 0, amount_paid: 0), :paid?
    assert_not_predicate Invoice.new(status: "AUTHORISED", amount_due: 100, amount_paid: 0), :paid?
  end
end

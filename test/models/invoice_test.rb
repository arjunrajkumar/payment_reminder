require "test_helper"

class InvoiceTest < ActiveSupport::TestCase
  test "belongs to an account invoice source and customer" do
    invoice = invoices(:xero_invoice)

    assert_equal accounts(:paid_jar), invoice.account
    assert_equal invoice_sources(:xero), invoice.invoice_source
    assert_equal customers(:xero_customer), invoice.customer
  end

  test "requires an external id" do
    invoice = invoice_sources(:xero).invoices.build(
      account: accounts(:paid_jar),
      customer: customers(:xero_customer)
    )

    assert_not invoice.valid?
    assert_includes invoice.errors[:external_id], "can't be blank"
  end

  test "does not allow the same external id twice for a source" do
    invoice = invoice_sources(:xero).invoices.build(
      account: accounts(:paid_jar),
      customer: customers(:xero_customer),
      external_id: invoices(:xero_invoice).external_id
    )

    assert_not invoice.valid?
    assert_includes invoice.errors[:external_id], "has already been taken"
  end

  test "classifies canonical receivable statuses" do
    open = Invoice.new(status: "open", amount_due: 100)
    paid = Invoice.new(status: "paid", amount_due: 0, amount_paid: 100)
    uncollectible = Invoice.new(status: "uncollectible", amount_due: 100)
    pending = Invoice.new(status: "pending", amount_due: 100)

    assert_predicate open, :issued?
    assert_predicate open, :open?
    assert_predicate open, :outstanding?
    assert_not_predicate open, :paid?
    assert_not_predicate open, :uncollectible?

    assert_predicate paid, :issued?
    assert_not_predicate paid, :open?
    assert_predicate paid, :paid?
    assert_not_predicate paid, :outstanding?

    assert_predicate uncollectible, :issued?
    assert_predicate uncollectible, :uncollectible?
    assert_not_predicate uncollectible, :outstanding?

    assert_not_predicate pending, :issued?
  end

  test "keeps partial payments open while a balance remains" do
    invoice = Invoice.new(status: "open", amount_due: 40, amount_paid: 60)

    assert_predicate invoice, :outstanding?
    assert_not_predicate invoice, :paid?
  end

  test "identifies overdue invoices from an open balance and due date" do
    as_of = Date.new(2026, 7, 11)

    assert Invoice.new(status: "open", amount_due: 100, due_on: as_of - 1.day).overdue?(as_of: as_of)
    assert_not Invoice.new(status: "open", amount_due: 100, due_on: as_of).overdue?(as_of: as_of)
    assert_not Invoice.new(status: "uncollectible", amount_due: 100, due_on: as_of - 1.day).overdue?(as_of: as_of)
  end

  test "queries canonical invoice states" do
    source = invoice_sources(:xero)
    as_of = Date.new(2026, 7, 11)
    open = create_invoice(source, "open", amount_due: 100, due_on: as_of - 1.day)
    paid = create_invoice(source, "paid", amount_due: 0, amount_paid: 100, due_on: as_of - 2.days)
    uncollectible = create_invoice(source, "uncollectible", amount_due: 75, due_on: as_of - 3.days)
    pending = create_invoice(source, "pending", amount_due: 50, due_on: as_of - 4.days)
    void = create_invoice(source, "void", amount_due: 25, due_on: as_of - 5.days)
    unknown = create_invoice(source, "unknown", amount_due: 10, due_on: as_of - 6.days)
    invoices = source.invoices.where(id: [ open, paid, uncollectible, pending, void, unknown ])

    assert_equal [ open, paid, uncollectible ].to_set, invoices.issued.to_set
    assert_equal [ open ], invoices.outstanding
    assert_equal [ paid ], invoices.paid
    assert_equal [ uncollectible ], invoices.uncollectible
    assert_equal [ open ], invoices.overdue(as_of: as_of)
  end

  private
    def create_invoice(source, status, amount_due:, due_on:, amount_paid: 0)
      source.invoices.create!(
        account: source.account,
        customer: customers(:xero_customer),
        external_id: SecureRandom.uuid,
        invoice_type: "ACCREC",
        provider_status: status,
        status: status,
        currency: "USD",
        amount_due: amount_due,
        amount_paid: amount_paid,
        total: amount_due + amount_paid,
        due_on: due_on
      )
    end
end

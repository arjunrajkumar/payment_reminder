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

  test "requires its account to match its invoice source account" do
    other_account = Account.create!(name: "Other Invoice Account")
    invoice = invoices(:xero_invoice).dup
    invoice.external_id = "mismatched-account-source"
    invoice.account = other_account

    assert_not invoice.valid?
    assert_includes invoice.errors[:account], "must match invoice source account"
  end

  test "requires its account to match its customer account" do
    other_account = Account.create!(name: "Other Customer Account")
    other_source = other_account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "other-customer-source"
    )
    other_customer = other_source.customers.create!(
      account: other_account,
      external_id: "other-customer",
      name: "Other Customer"
    )
    invoice = invoices(:xero_invoice).dup
    invoice.external_id = "mismatched-account-customer"
    invoice.customer = other_customer

    assert_not invoice.valid?
    assert_includes invoice.errors[:account], "must match customer account"
  end

  test "requires its invoice source to match its customer invoice source" do
    account = accounts(:paid_jar)
    other_source = account.invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: "other-invoice-source"
    )
    other_customer = other_source.customers.create!(
      account: account,
      external_id: "other-source-customer",
      name: "Other Source Customer"
    )
    invoice = invoices(:xero_invoice).dup
    invoice.external_id = "mismatched-source-customer"
    invoice.customer = other_customer

    assert_not invoice.valid?
    assert_includes invoice.errors[:invoice_source], "must match customer invoice source"
  end

  test "classifies canonical invoice statuses" do
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

  test "reports its effective status as of a date" do
    as_of = Date.new(2026, 7, 11)
    overdue = Invoice.new(status: "open", amount_due: 100, due_on: as_of - 1.day)

    assert_equal "overdue", overdue.status_as_of(as_of: as_of)
    assert_equal "open", overdue.status
    assert_equal "outstanding", Invoice.new(status: "open", amount_due: 100, due_on: as_of).status_as_of(as_of: as_of)
    assert_equal "outstanding", Invoice.new(status: "open", amount_due: 100, due_on: as_of + 1.day).status_as_of(as_of: as_of)
    assert_equal "outstanding", Invoice.new(status: "open", amount_due: 100, due_on: nil).status_as_of(as_of: as_of)
    assert_equal "open", Invoice.new(status: "open", amount_due: 0, due_on: as_of + 1.day).status_as_of(as_of: as_of)
    assert_equal "paid", Invoice.new(status: "paid", amount_due: 0, due_on: as_of - 1.day).status_as_of(as_of: as_of)
  end

  test "queries canonical invoice states" do
    source = invoice_sources(:xero)
    as_of = Date.new(2026, 7, 11)
    open = create_invoice(source, "open", amount_due: 100, due_on: as_of - 1.day)
    paid = create_invoice(source, "paid", amount_due: 0, amount_paid: 100, due_on: as_of - 2.days, paid_on: as_of - 1.day)
    uncollectible = create_invoice(source, "uncollectible", amount_due: 75, due_on: as_of - 3.days)
    pending = create_invoice(source, "pending", amount_due: 50, due_on: as_of - 4.days)
    void = create_invoice(source, "void", amount_due: 25, due_on: as_of - 5.days)
    unknown = create_invoice(source, "unknown", amount_due: 10, due_on: as_of - 6.days)
    invoices = source.invoices.where(id: [ open, paid, uncollectible, pending, void, unknown ])

    assert_equal [ open, paid, uncollectible ].to_set, invoices.issued.to_set
    assert_equal [ open ], invoices.open
    assert_equal [ open ], invoices.outstanding
    assert_equal [ paid ], invoices.paid
    assert_equal [ uncollectible ], invoices.uncollectible
    assert_equal [ open ], invoices.overdue(as_of: as_of)
  end

  test "orders the invoice index with problematic invoices first" do
    source = invoice_sources(:xero)
    as_of = Date.new(2026, 7, 15)

    paid = create_index_invoice(source, "paid", company: "Acme Paid", status: "paid", amount_due: 0, due_on: as_of - 1.month)
    current_beta = create_index_invoice(source, "current-beta", company: "Beta Current", status: "open", amount_due: 100, due_on: as_of + 1.week)
    open_zero = create_index_invoice(source, "open-zero", company: "Zero Open", status: "open", amount_due: 0, due_on: as_of + 1.week)
    pending = create_index_invoice(source, "pending", company: "Acme Pending", status: "pending", amount_due: 100, due_on: as_of + 2.weeks)
    overdue = create_index_invoice(source, "overdue", company: "Zeta Overdue", status: "open", amount_due: 100, due_on: as_of - 1.day)
    void = create_index_invoice(source, "void", company: "Acme Void", status: "void", amount_due: 0, due_on: as_of - 2.months)
    uncollectible = create_index_invoice(source, "uncollectible", company: "Zeta Uncollectible", status: "uncollectible", amount_due: 100, due_on: as_of - 1.month)
    current_alpha = create_index_invoice(source, "current-alpha", company: "Alpha Current", status: "open", amount_due: 100, due_on: as_of + 1.week)
    unknown = create_index_invoice(source, "unknown", company: "Zeta Unknown", status: "unknown", amount_due: 100, due_on: as_of)

    invoices = source.invoices.where(id: [ paid, current_beta, open_zero, pending, overdue, void, uncollectible, current_alpha, unknown ])

    assert_kind_of ActiveRecord::Relation, invoices.for_index(as_of: as_of)
    assert_equal(
      [ overdue, uncollectible, unknown, current_alpha, current_beta, open_zero, pending, paid, void ],
      invoices.for_index(as_of: as_of).to_a
    )
  end

  private
    def create_invoice(source, status, amount_due:, due_on:, amount_paid: 0, paid_on: nil)
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
        due_on: due_on,
        paid_on: paid_on
      )
    end

    def create_index_invoice(source, external_id, company:, status:, amount_due:, due_on:)
      customer = source.customers.create!(
        account: source.account,
        external_id: "customer-#{external_id}",
        name: company
      )

      source.invoices.create!(
        account: source.account,
        customer: customer,
        external_id: external_id,
        number: "INV-#{external_id.upcase}",
        invoice_type: "ACCREC",
        provider_status: status,
        status: status,
        currency: "USD",
        amount_due: amount_due,
        amount_paid: 0,
        total: amount_due,
        issued_on: Date.new(2026, 7, 1),
        due_on: due_on
      )
    end
end

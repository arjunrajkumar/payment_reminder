require "test_helper"

class CustomerTest < ActiveSupport::TestCase
  setup do
    @source = invoice_sources(:xero)
    @customer = @source.customers.create!(
      account: @source.account,
      external_id: SecureRandom.uuid,
      name: "Example Customer",
      email: "customer@example.com"
    )
  end

  test "belongs to an account and invoice source" do
    assert_equal @source.account, @customer.account
    assert_equal @source, @customer.invoice_source
  end

  test "requires provider identity and a name" do
    customer = @source.customers.build(account: @source.account)

    assert_not customer.valid?
    assert_includes customer.errors[:external_id], "can't be blank"
    assert_includes customer.errors[:name], "can't be blank"
  end

  test "keeps provider customer identities separate by invoice source" do
    duplicate = @source.customers.build(
      account: @source.account,
      external_id: @customer.external_id,
      name: "Duplicate"
    )
    stripe = @source.account.invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: SecureRandom.uuid
    )
    other_provider_customer = stripe.customers.build(
      account: stripe.account,
      external_id: @customer.external_id,
      name: @customer.name
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:external_id], "has already been taken"
    assert_predicate other_provider_customer, :valid?
  end

  test "refreshes customer details without replacing them with blanks" do
    observed_at = Time.zone.local(2026, 7, 10)
    updated = Customer.sync_from_provider!(
      invoice_source: @source,
      external_id: @customer.external_id,
      name: "Updated Customer",
      email: "updated@example.com",
      observed_at: observed_at
    )
    unchanged = Customer.sync_from_provider!(
      invoice_source: @source,
      external_id: @customer.external_id,
      name: nil,
      email: nil,
      observed_at: observed_at
    )

    assert_equal @customer, updated
    assert_equal @customer, unchanged
    assert_equal "Updated Customer", unchanged.name
    assert_equal "updated@example.com", unchanged.email
  end

  test "does not replace newer customer details with an older invoice snapshot" do
    newer_observation = Time.zone.local(2026, 7, 10)
    older_observation = Time.zone.local(2026, 6, 10)

    Customer.sync_from_provider!(
      invoice_source: @source,
      external_id: @customer.external_id,
      name: "Current Name",
      email: "current@example.com",
      observed_at: newer_observation
    )
    customer = Customer.sync_from_provider!(
      invoice_source: @source,
      external_id: @customer.external_id,
      name: "Historical Name",
      email: "historical@example.com",
      observed_at: older_observation
    )

    assert_equal "Current Name", customer.name
    assert_equal "current@example.com", customer.email
    assert_equal newer_observation, customer.details_observed_at
  end

  test "finds only customers with issued invoices" do
    pending_customer = @source.customers.create!(
      account: @source.account,
      external_id: SecureRandom.uuid,
      name: "Pending Customer"
    )
    invoice(customer: @customer, status: "open")
    invoice(customer: pending_customer, status: "pending")

    assert_includes Customer.with_issued_invoices, @customer
    assert_not_includes Customer.with_issued_invoices, pending_customer
  end

  test "summarizes paid and outstanding invoice behavior" do
    paid_early = invoice(
      issued_on: Date.new(2026, 1, 1),
      due_on: Date.new(2026, 1, 31),
      paid_on: Date.new(2026, 1, 29),
      status: "paid",
      total: 100,
      amount_due: 0,
      amount_paid: 100
    )
    paid_late = invoice(
      issued_on: Date.new(2026, 3, 1),
      due_on: Date.new(2026, 3, 31),
      paid_on: Date.new(2026, 4, 10),
      status: "paid",
      total: 200,
      amount_due: 0,
      amount_paid: 200
    )
    outstanding = invoice(
      issued_on: Date.new(2026, 6, 1),
      due_on: Date.new(2026, 6, 30),
      total: 300,
      amount_due: 300
    )

    travel_to Time.zone.local(2026, 7, 11, 12) do
      assert_equal [ outstanding ], @customer.outstanding_invoices
      assert_equal [ outstanding ], @customer.overdue_invoices
      assert_equal [ paid_late, paid_early ], @customer.paid_invoices
      assert_equal({ "INR" => 300.to_d }, @customer.outstanding_totals)
      assert_equal 2, @customer.payment_history_count
      assert_equal 50, @customer.on_time_rate
      assert_equal 4, @customer.forecast_days_from_due
      assert_equal "Low", @customer.forecast_confidence
      assert_equal 11, @customer.oldest_overdue_days
      assert_equal Date.new(2026, 4, 10), @customer.last_payment_on
    end
  end

  test "excludes an unusual payment date from its timing forecast" do
    invoice(due_on: Date.new(2026, 7, 31), paid_on: Date.new(2026, 1, 29), status: "paid", amount_due: 0, amount_paid: 100)
    invoice(due_on: Date.new(2026, 2, 28), paid_on: Date.new(2026, 2, 28), status: "paid", amount_due: 0, amount_paid: 100)
    invoice(due_on: Date.new(2026, 3, 31), paid_on: Date.new(2026, 3, 28), status: "paid", amount_due: 0, amount_paid: 100)

    assert_equal(-2, @customer.forecast_days_from_due)
    assert_equal "Low", @customer.forecast_confidence
  end

  test "builds invoice timing events around the due date" do
    paid = invoice(due_on: Date.new(2026, 7, 1), paid_on: Date.new(2026, 6, 28), status: "paid", amount_due: 0, amount_paid: 100)
    paid_without_date = invoice(due_on: Date.new(2026, 6, 30), status: "paid", amount_due: 0, amount_paid: 100)
    outstanding = invoice(due_on: Date.new(2026, 7, 6), amount_due: 100)
    invoice(due_on: nil, amount_due: 100)

    travel_to Time.zone.local(2026, 7, 11, 12) do
      events = @customer.invoice_timing_events

      assert_equal [ outstanding, paid, paid_without_date ], events.map { |event| event.fetch(:invoice) }
      assert_equal [ 5, -3, nil ], events.map { |event| event.fetch(:delay) }
      assert_equal [ false, true, true ], events.map { |event| event.fetch(:paid) }
      assert_in_delta 58.3, events.first.fetch(:position), 0.1
      assert_in_delta 45.0, events.second.fetch(:position), 0.1
      assert_nil events.third.fetch(:position)
    end
  end

  test "keeps an uncollectible invoice out of collection and payment timing" do
    uncollectible = invoice(
      due_on: Date.new(2026, 6, 1),
      status: "uncollectible",
      amount_due: 100
    )

    travel_to Time.zone.local(2026, 7, 11, 12) do
      event = @customer.invoice_timing_events.first

      assert_empty @customer.outstanding_invoices
      assert_empty @customer.overdue_invoices
      assert_empty @customer.paid_invoices
      assert_equal [ uncollectible ], @customer.uncollectible_invoices
      assert_equal({ "INR" => 100.to_d }, @customer.uncollectible_totals)
      assert event.fetch(:uncollectible)
      assert_nil event.fetch(:delay)
      assert_nil event.fetch(:position)
    end
  end

  test "keeps an open invoice with no balance out of paid and overdue timing" do
    open_without_balance = invoice(
      due_on: Date.new(2026, 6, 1),
      status: "open",
      total: 100,
      amount_due: 0,
      amount_paid: 0
    )

    travel_to Time.zone.local(2026, 7, 11, 12) do
      event = @customer.invoice_timing_events.first

      assert_equal [ open_without_balance ], @customer.open_invoices
      assert_empty @customer.outstanding_invoices
      assert_empty @customer.overdue_invoices
      assert_empty @customer.paid_invoices
      assert event.fetch(:no_balance_due)
      assert_nil event.fetch(:delay)
      assert_nil event.fetch(:position)
    end
  end

  test "uses the earliest due invoice and due-date-only confidence without paid history" do
    later = invoice(due_on: Date.new(2026, 8, 1), amount_due: 200)
    earlier = invoice(due_on: Date.new(2026, 7, 25), amount_due: 100)
    invoice(due_on: nil, amount_due: 50)

    assert_equal earlier, @customer.next_expected_invoice
    assert_nil @customer.forecast_days_from_due
    assert_equal "Due date only", @customer.forecast_confidence
    assert_not_equal later, @customer.next_expected_invoice
  end

  private
    def invoice(
      customer: @customer,
      issued_on: Date.new(2026, 7, 1),
      due_on: Date.new(2026, 7, 31),
      paid_on: nil,
      status: "open",
      total: 100,
      amount_due: 100,
      amount_paid: 0
    )
      customer.invoices.create!(
        account: customer.account,
        invoice_source: customer.invoice_source,
        invoice_type: "ACCREC",
        external_id: SecureRandom.uuid,
        contact_external_id: customer.external_id,
        contact_name: customer.name,
        currency: "INR",
        issued_on: issued_on,
        due_on: due_on,
        paid_on: paid_on,
        provider_status: status,
        status: status,
        total: total,
        amount_due: amount_due,
        amount_paid: amount_paid
      )
    end
end

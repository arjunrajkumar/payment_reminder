require "test_helper"

class Customers::ProfileTest < ActiveSupport::TestCase
  test "summarizes paid and outstanding invoice behavior" do
    as_of = Date.new(2026, 7, 11)
    paid_early = invoice(
      issued_on: Date.new(2026, 1, 1),
      due_on: Date.new(2026, 1, 31),
      paid_on: Date.new(2026, 1, 29),
      status: "PAID",
      total: 100,
      amount_due: 0,
      amount_paid: 100
    )
    paid_late = invoice(
      issued_on: Date.new(2026, 3, 1),
      due_on: Date.new(2026, 3, 31),
      paid_on: Date.new(2026, 4, 10),
      status: "PAID",
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

    profile = profile_for([ paid_early, paid_late, outstanding ], as_of: as_of)

    assert_equal "Example Customer", profile.name
    assert_equal 3, profile.invoices.size
    assert_equal [ outstanding ], profile.outstanding_invoices
    assert_equal [ outstanding ], profile.overdue_invoices
    assert_equal [ paid_late, paid_early ], profile.paid_invoices
    assert_equal({ "INR" => 300.to_d }, profile.outstanding_totals)
    assert_equal 2, profile.payment_history_count
    assert_equal 50, profile.on_time_rate
    assert_equal 4, profile.forecast_days_from_due
    assert_equal "Low", profile.forecast_confidence
    assert_equal 11, profile.oldest_overdue_days
    assert_equal Date.new(2026, 4, 10), profile.last_payment_on
  end

  test "uses normalized names as identity when the provider has no contact id" do
    first = invoice(contact_external_id: nil, contact_name: "  Example   Customer ")
    second = invoice(contact_external_id: nil, contact_name: "example customer")

    first_identity = Customers::Profile.identity_for(first)
    second_identity = Customers::Profile.identity_for(second)

    assert_equal first_identity, second_identity
    assert_equal [ first.invoice_source_id, "name", "example customer" ], first_identity
  end

  test "uses the contact id as identity when it is available" do
    customer_invoice = invoice(contact_external_id: "contact-456", contact_name: "Renamed Customer")

    assert_equal(
      [ customer_invoice.invoice_source_id, "contact", "contact-456" ],
      Customers::Profile.identity_for(customer_invoice)
    )
  end

  test "uses customer email data from either supported provider shape" do
    stripe_invoice = invoice(provider_data: { "customer_email" => "stripe@example.com" })
    xero_invoice = invoice(raw_data: { "Contact" => { "EmailAddress" => "xero@example.com" } })

    assert_equal "stripe@example.com", profile_for([ stripe_invoice ]).email
    assert_equal "xero@example.com", profile_for([ xero_invoice ]).email
  end

  test "excludes an unusual payment date from its timing forecast" do
    invoices = [
      invoice(due_on: Date.new(2026, 7, 31), paid_on: Date.new(2026, 1, 29), status: "PAID", amount_due: 0, amount_paid: 100),
      invoice(due_on: Date.new(2026, 2, 28), paid_on: Date.new(2026, 2, 28), status: "PAID", amount_due: 0, amount_paid: 100),
      invoice(due_on: Date.new(2026, 3, 31), paid_on: Date.new(2026, 3, 28), status: "PAID", amount_due: 0, amount_paid: 100)
    ]

    profile = profile_for(invoices, as_of: Date.new(2026, 7, 11))

    assert_equal(-2, profile.forecast_days_from_due)
    assert_equal "Low", profile.forecast_confidence
  end

  test "builds invoice timing events around the due date" do
    as_of = Date.new(2026, 7, 11)
    paid = invoice(due_on: Date.new(2026, 7, 1), paid_on: Date.new(2026, 6, 28), status: "PAID", amount_due: 0, amount_paid: 100)
    paid_without_date = invoice(due_on: Date.new(2026, 6, 30), status: "PAID", amount_due: 0, amount_paid: 100)
    outstanding = invoice(due_on: Date.new(2026, 7, 6), amount_due: 100)
    undated = invoice(due_on: nil, amount_due: 100)

    events = profile_for([ paid, paid_without_date, outstanding, undated ], as_of: as_of).invoice_timing_events

    assert_equal [ outstanding, paid, paid_without_date ], events.map { |event| event.fetch(:invoice) }
    assert_equal [ 5, -3, nil ], events.map { |event| event.fetch(:delay) }
    assert_equal [ false, true, true ], events.map { |event| event.fetch(:paid) }
    assert_in_delta 58.3, events.first.fetch(:position), 0.1
    assert_in_delta 45.0, events.second.fetch(:position), 0.1
    assert_nil events.third.fetch(:position)
  end

  test "uses the earliest due invoice and due-date-only confidence without paid history" do
    later = invoice(due_on: Date.new(2026, 8, 1), amount_due: 200)
    earlier = invoice(due_on: Date.new(2026, 7, 25), amount_due: 100)
    undated = invoice(due_on: nil, amount_due: 50)

    profile = profile_for([ later, undated, earlier ], as_of: Date.new(2026, 7, 11))

    assert_equal earlier, profile.next_expected_invoice
    assert_nil profile.forecast_days_from_due
    assert_equal "Due date only", profile.forecast_confidence
  end

  private
    def profile_for(invoices, as_of: Date.new(2026, 7, 11))
      Customers::Profile.new(
        invoices,
        identity: Customers::Profile.identity_for(invoices.first),
        as_of: as_of
      )
    end

    def invoice(
      contact_external_id: "contact-123",
      contact_name: "Example Customer",
      issued_on: Date.new(2026, 7, 1),
      due_on: Date.new(2026, 7, 31),
      paid_on: nil,
      status: "AUTHORISED",
      total: 100,
      amount_due: 100,
      amount_paid: 0,
      provider_data: {},
      raw_data: {}
    )
      Invoice.new(
        invoice_source: invoice_sources(:xero),
        invoice_type: "ACCREC",
        external_id: SecureRandom.uuid,
        contact_external_id: contact_external_id,
        contact_name: contact_name,
        currency: "INR",
        issued_on: issued_on,
        due_on: due_on,
        paid_on: paid_on,
        status: status,
        total: total,
        amount_due: amount_due,
        amount_paid: amount_paid,
        provider_data: provider_data,
        raw_data: raw_data
      )
    end
end

require "test_helper"

class Customer::SegmentationTest < ActiveSupport::TestCase
  setup do
    @source = invoice_sources(:xero)
    @customer = @source.customers.create!(
      account: @source.account,
      external_id: SecureRandom.uuid,
      name: "Segment Customer"
    )
    @invoice_sequence = 0
  end

  test "rates customers with fewer than three completed outcomes as normal debtors" do
    assert_equal "normal_debtor", segment_after_payments(0, 0)
  end

  test "rates customers with exactly three completed outcomes" do
    assert_equal "good_debtor", segment_after_payments(0, 0, 0)
  end

  test "rates customers at the good debtor boundary as good debtors" do
    assert_equal "good_debtor", segment_after_payments(0, 0, 0, 0, 1)
  end

  test "rates customers between the configured boundaries as normal debtors" do
    assert_equal "normal_debtor", segment_after_payments(0, 0, 1)
  end

  test "rates customers at the bad debtor boundary as normal debtors" do
    assert_equal "normal_debtor", segment_after_payments(0, 0, 1, 1)
  end

  test "rates customers below the bad debtor boundary as bad debtors" do
    assert_equal "bad_debtor", segment_after_payments(0, 1, 1)
  end

  test "ignores open overdue invoices until they are resolved" do
    travel_to Time.zone.local(2026, 7, 16, 12) do
      paid_invoice(delay: 0, due_on: Date.new(2026, 2, 28))
      paid_invoice(delay: 0, due_on: Date.new(2026, 3, 31))
      invoice(status: "open", due_on: Date.current - 10.days)

      assert_equal "normal_debtor", refreshed_segment
    end
  end

  test "counts uncollectible invoices as completed outcomes that were not on time" do
    paid_invoice(delay: 0)
    invoice(status: "uncollectible", due_on: next_due_on)
    invoice(status: "uncollectible", due_on: next_due_on)

    assert_equal "bad_debtor", refreshed_segment
  end

  test "does not make one uncollectible invoice an automatic bad debtor" do
    paid_invoice(delay: 0)
    paid_invoice(delay: 0)
    invoice(status: "uncollectible", due_on: next_due_on)

    assert_equal "normal_debtor", refreshed_segment
  end

  test "uses the latest twelve outcomes by completion date" do
    @customer.account.customer_segment(:good_debtor).update!(on_time_rate: 100)

    12.times do |month|
      due_on = Date.new(2025, month + 1, 20)
      paid_invoice(delay: 0, due_on: due_on)
    end
    invoice(
      status: "uncollectible",
      amount_due: 100,
      issued_on: Date.new(2024, 1, 1),
      due_on: Date.new(2024, 1, 31),
      completed_on: Date.new(2026, 1, 15)
    )

    assert_equal "normal_debtor", refreshed_segment
  end

  test "counts fully paid future-due invoices as completed on-time outcomes" do
    travel_to Time.zone.local(2026, 7, 16, 12) do
      paid_invoice(delay: 0, due_on: Date.new(2026, 2, 28))
      paid_invoice(delay: 0, due_on: Date.new(2026, 3, 31))
      paid_invoice(delay: -10, due_on: Date.current + 5.days)

      assert_equal "good_debtor", refreshed_segment
    end
  end

  test "ignores paid invoices without the dates needed to measure on-time payment" do
    paid_invoice(delay: 0)
    paid_invoice(delay: 0)
    invoice(status: "paid", paid_on: Date.new(2026, 1, 20), due_on: nil, amount_due: 0, amount_paid: 100)
    invoice(status: "paid", paid_on: nil, due_on: next_due_on, amount_due: 0, amount_paid: 100)

    assert_equal "normal_debtor", refreshed_segment
  end

  test "ignores draft invoices" do
    paid_invoice(delay: 0)
    paid_invoice(delay: 0)
    invoice(status: "pending", due_on: next_due_on)

    assert_equal "normal_debtor", refreshed_segment
  end

  test "uses the configurable good debtor on-time rate" do
    @customer.account.customer_segment(:good_debtor).update!(on_time_rate: 65)

    assert_equal "good_debtor", segment_after_payments(0, 0, 5)
  end

  test "uses the configurable bad debtor on-time rate as an exclusive boundary" do
    @customer.account.customer_segment(:bad_debtor).update!(on_time_rate: 40)

    assert_equal "normal_debtor", segment_after_payments(0, 0, 10, 20, 25)
  end

  private
    def segment_after_payments(*payment_delays)
      payment_delays.each { |delay| paid_invoice(delay:) }
      refreshed_segment
    end

    def refreshed_segment
      @customer.refresh_customer_segment!
      @customer.reload.payer_segment
    end

    def paid_invoice(delay:, due_on: next_due_on, issued_on: due_on - 30.days)
      invoice(
        status: "paid",
        issued_on: issued_on,
        due_on: due_on,
        paid_on: due_on + delay.days,
        amount_due: 0,
        amount_paid: 100
      )
    end

    def next_due_on
      @invoice_sequence += 1
      Date.new(2025, 1, 31) + @invoice_sequence.months
    end

    def invoice(
      status: "open",
      issued_on: Date.new(2026, 7, 1),
      due_on: Date.new(2026, 7, 31),
      paid_on: nil,
      completed_on: nil,
      amount_due: 100,
      amount_paid: 0
    )
      @customer.invoices.create!(
        account: @customer.account,
        invoice_source: @source,
        invoice_type: "ACCREC",
        external_id: SecureRandom.uuid,
        contact_external_id: @customer.external_id,
        contact_name: @customer.name,
        currency: "INR",
        issued_on: issued_on,
        due_on: due_on,
        paid_on: paid_on,
        completed_on: completed_on,
        provider_status: status,
        status: status,
        total: amount_due + amount_paid,
        amount_due: amount_due,
        amount_paid: amount_paid
      )
    end
end

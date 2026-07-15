require "test_helper"

class Customer::PayerSegmentTest < ActiveSupport::TestCase
  setup do
    @source = invoice_sources(:xero)
    @customer = @source.customers.create!(
      account: @source.account,
      external_id: SecureRandom.uuid,
      name: "Segment Customer"
    )
    @invoice_sequence = 0
  end

  test "classifies customers with limited payment history as new" do
    assert_equal "new", segment_after_payments(0, 0)
  end

  test "classifies any recent uncollectible invoice as unreliable" do
    invoice(status: "uncollectible", amount_due: 100, due_on: next_due_on)

    assert_equal "unreliable_payer", refreshed_segment
  end

  test "classifies customers that reliably pay by the due date" do
    assert_equal "pays_on_time", segment_after_payments(-1, 0, 0)
  end

  test "classifies customers with mixed timing as sometimes late" do
    assert_equal "sometimes_late", segment_after_payments(0, 3, 7)
  end

  test "classifies customers whose typical payment is late as slow payers" do
    assert_equal "slow_payer", segment_after_payments(8, 9, 10)
  end

  test "classifies a long and inconsistent late history as unreliable" do
    assert_equal "unreliable_payer", segment_after_payments(0, 8, 10, 20, 25)
  end

  test "uses only the latest twelve eligible payment outcomes" do
    older_due_on = Date.new(2024, 12, 20)
    invoice(
      status: "uncollectible",
      amount_due: 100,
      issued_on: older_due_on - 20.days,
      due_on: older_due_on
    )

    12.times do |month|
      due_on = Date.new(2025, month + 1, 20)
      paid_invoice(delay: 0, due_on: due_on)
    end

    invoice(
      status: "paid",
      amount_due: 0,
      amount_paid: 100,
      issued_on: Date.new(2026, 1, 1),
      due_on: nil,
      paid_on: Date.new(2026, 1, 20)
    )

    assert_equal "pays_on_time", refreshed_segment
  end

  test "keeps an unusual early payment from changing an on-time segment" do
    paid_invoice(delay: -183, due_on: Date.new(2026, 7, 31))
    paid_invoice(delay: 0, due_on: Date.new(2026, 2, 28))
    paid_invoice(delay: -3, due_on: Date.new(2026, 3, 31))

    assert_equal "pays_on_time", refreshed_segment
  end

  test "uses the account minimum payment history" do
    @customer.account.update!(payer_segment_minimum_payment_history: 4)

    assert_equal "new", segment_after_payments(0, 0, 0)
  end

  test "uses the account pays-on-time rate" do
    @customer.account.update!(payer_segment_pays_on_time_rate: 65)

    assert_equal "pays_on_time", segment_after_payments(0, 0, 5)
  end

  test "uses the account slow-payer delay" do
    @customer.account.update!(payer_segment_slow_payer_days: 10)

    assert_equal "sometimes_late", segment_after_payments(8, 9, 10)
  end

  test "uses the account minimum unreliable history" do
    @customer.account.update!(payer_segment_minimum_unreliable_history: 6)

    assert_equal "slow_payer", segment_after_payments(0, 8, 10, 20, 25)
  end

  test "uses the account unreliable on-time rate" do
    @customer.account.update!(payer_segment_unreliable_on_time_rate: 40)

    assert_equal "slow_payer", segment_after_payments(0, 0, 10, 20, 25)
  end

  private
    def segment_after_payments(*payment_delays)
      payment_delays.each { |delay| paid_invoice(delay:) }
      refreshed_segment
    end

    def refreshed_segment
      @customer.refresh_payer_segment!
      @customer.reload.payer_segment
    end

    def paid_invoice(delay:, due_on: next_due_on)
      invoice(
        status: "paid",
        issued_on: due_on - 30.days,
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
        provider_status: status,
        status: status,
        total: amount_due + amount_paid,
        amount_due: amount_due,
        amount_paid: amount_paid
      )
    end
end

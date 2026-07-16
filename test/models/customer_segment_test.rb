require "test_helper"

class CustomerSegmentTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
  end

  test "belongs to an account and has customers" do
    segment = customer_segments(:normal_debtor_segment)

    assert_equal @account, segment.account
    assert_includes segment.customers, customers(:xero_customer)
  end

  test "requires one debtor rating type per account" do
    duplicate = CustomerSegment.new(
      account: @account,
      payer_segment: :good_debtor,
      on_time_rate: 80
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:payer_segment], "has already been taken"
  end

  test "requires a supported debtor rating type" do
    segment = CustomerSegment.new(account: @account, payer_segment: "unknown_segment")

    assert_not segment.valid?
    assert_predicate segment.errors[:payer_segment], :any?
  end

  test "requires supported on-time rate values for configurable ratings" do
    invalid_rules = [
      [ :good_debtor, 81 ],
      [ :bad_debtor, -5 ]
    ]

    invalid_rules.each do |payer_segment, value|
      segment = @account.customer_segment(payer_segment)
      segment.on_time_rate = value

      assert_not segment.valid?, "expected #{payer_segment}.on_time_rate=#{value} to be invalid"
      assert_predicate segment.errors[:on_time_rate], :any?
    end
  end

  test "normal debtor has no independently configurable rate" do
    segment = @account.customer_segment(:normal_debtor)
    segment.on_time_rate = 60

    assert_not segment.valid?
    assert_includes segment.errors[:on_time_rate], "must be blank"
  end

  test "prevents a direct update from making debtor rating boundaries overlap" do
    good_segment = @account.customer_segment(:good_debtor)
    good_segment.on_time_rate = 50

    assert_not good_segment.valid?
    assert_includes good_segment.errors[:on_time_rate], "must stay above the Bad Debtor on-time rate"
  end

  test "prevents an account customer segment from being removed directly" do
    segment = @account.customer_segment(:good_debtor)

    assert_not segment.destroy
    assert_includes segment.errors[:base], "Account customer segments cannot be removed"
  end

  test "removes customer segments when their account is removed" do
    account = Account.create!(name: "Disposable Segment Account")

    assert_difference -> { CustomerSegment.count }, -3 do
      account.destroy!
    end
  end
end

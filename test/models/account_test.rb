require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "has many users" do
    assert_includes accounts(:paid_jar).users, users(:arjun)
  end

  test "has many invoice sources" do
    assert_includes accounts(:paid_jar).invoice_sources, invoice_sources(:xero)
  end

  test "has many invoices" do
    assert_includes accounts(:paid_jar).invoices, invoices(:xero_invoice)
  end

  test "has many customers" do
    assert_includes accounts(:paid_jar).customers, customers(:xero_customer)
  end

  test "creates account with owner and system user" do
    identity = Identity.create!(email_address: "owner@example.com")
    account = Account.create_with_owner(
      account: { name: "Owner Account" },
      owner: { name: "Owner User", identity: identity }
    )

    assert_predicate account.users.find_by!(role: :system), :system?
    assert_predicate account.users.find_by!(identity: identity), :owner?
  end

  test "rolls back account when owner creation fails" do
    identity = Identity.create!(email_address: "invalid-owner@example.com")

    assert_no_difference [ -> { Account.count }, -> { User.count } ] do
      assert_raises ActiveRecord::RecordInvalid do
        Account.create_with_owner(
          account: { name: "Invalid Owner Account" },
          owner: { name: "", identity: identity }
        )
      end
    end
  end

  test "slug" do
    assert_equal "/#{accounts(:paid_jar).external_account_id}", accounts(:paid_jar).slug
  end

  test "external account id auto-increments on creation" do
    account1 = Account.create!(name: "First Account")
    account2 = Account.create!(name: "Second Account")

    assert_not_nil account1.external_account_id
    assert_not_nil account2.external_account_id
    assert_equal account1.external_account_id + 1, account2.external_account_id
  end

  test "external account id can be overridden" do
    custom_id = 999999
    sequence = Account::ExternalIdSequence.first_or_create!(value: 0)
    sequence_value_before = sequence.value

    account = Account.create!(name: "Custom ID Account", external_account_id: custom_id)

    assert_equal custom_id, account.external_account_id
    assert_equal sequence_value_before, sequence.reload.value
  end

  test "requires a name" do
    account = Account.new

    assert_not account.valid?
    assert_includes account.errors[:name], "can't be blank"
  end

  test "uses the current payer segment rule defaults" do
    account = Account.new(name: "Segment Defaults")

    assert_equal 3, account.payer_segment_minimum_payment_history
    assert_equal 5, account.payer_segment_minimum_unreliable_history
    assert_equal 80, account.payer_segment_pays_on_time_rate
    assert_equal 50, account.payer_segment_unreliable_on_time_rate
    assert_equal 7, account.payer_segment_slow_payer_days
  end

  test "requires supported payer segment rule values" do
    invalid_rules = {
      payer_segment_minimum_payment_history: 0,
      payer_segment_minimum_unreliable_history: 13,
      payer_segment_pays_on_time_rate: 81,
      payer_segment_unreliable_on_time_rate: 76,
      payer_segment_slow_payer_days: 2
    }

    invalid_rules.each do |attribute, value|
      account = Account.new(name: "Invalid Segment Rules", attribute => value)

      assert_not account.valid?, "expected #{attribute}=#{value} to be invalid"
      assert_predicate account.errors[attribute], :any?
    end
  end

  test "keeps unreliable payer thresholds below the broader rules" do
    account = Account.new(
      name: "Overlapping Segment Rules",
      payer_segment_minimum_payment_history: 6,
      payer_segment_minimum_unreliable_history: 5,
      payer_segment_pays_on_time_rate: 50,
      payer_segment_unreliable_on_time_rate: 50
    )

    assert_not account.valid?
    assert_includes account.errors[:payer_segment_minimum_unreliable_history], "must be at least the minimum payment history"
    assert_includes account.errors[:payer_segment_unreliable_on_time_rate], "must be lower than the pays-on-time rate"
  end

  test "refreshes every customer payer segment" do
    account = Account.create!(name: "Segment Refresh Account")
    source = account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "segment-refresh-source"
    )
    source.customers.create!(
      account: account,
      external_id: "segment-refresh-customer",
      name: "Segment Refresh Customer"
    )

    Customer.any_instance.expects(:refresh_payer_segment!).once

    assert_same account, account.refresh_payer_segments!
  end
end

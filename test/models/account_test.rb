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
end

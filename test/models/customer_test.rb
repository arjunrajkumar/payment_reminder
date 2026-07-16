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

  test "belongs to an account invoice source and customer segment" do
    assert_equal @source.account, @customer.account
    assert_equal @source, @customer.invoice_source
    assert_equal @source.account.customer_segment(:normal_debtor), @customer.customer_segment
  end

  test "starts in the account normal debtor segment" do
    assert_equal @source.account.customer_segment(:normal_debtor), @customer.customer_segment
    assert_equal "normal_debtor", @customer.payer_segment
  end

  test "provider sync assigns new customers to the account normal debtor segment" do
    customer = Customer.sync_from_provider!(
      invoice_source: @source,
      external_id: SecureRandom.uuid,
      name: "Provider Customer",
      email: "provider@example.com"
    )

    assert_equal @source.account.customer_segment(:normal_debtor), customer.customer_segment
  end

  test "requires its customer segment to belong to its account" do
    other_account = Account.create!(name: "Other Customer Segment Account")
    customer = @source.customers.build(
      account: @source.account,
      customer_segment: other_account.customer_segment(:normal_debtor),
      external_id: SecureRandom.uuid,
      name: "Mismatched Segment Customer"
    )

    assert_not customer.valid?
    assert_includes customer.errors[:customer_segment], "must belong to the customer account"
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
end

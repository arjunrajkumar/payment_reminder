require "test_helper"

class InvoiceIntegrationTest < ActiveSupport::TestCase
  test "belongs to an account" do
    assert_equal accounts(:paid_jar), invoice_integrations(:xero).account
  end

  test "requires provider and external account id" do
    integration = accounts(:paid_jar).invoice_integrations.build

    assert_not integration.valid?
    assert_includes integration.errors[:provider], "can't be blank"
    assert_includes integration.errors[:external_account_id], "can't be blank"
  end

  test "defaults to pending status" do
    integration = accounts(:paid_jar).invoice_integrations.build(
      provider: "stripe",
      external_account_id: "acct_123"
    )

    assert_predicate integration, :pending?
  end

  test "allows multiple accounts for the same provider" do
    integration = accounts(:paid_jar).invoice_integrations.create!(
      provider: "xero",
      external_account_id: "xero-tenant-456"
    )

    assert integration.persisted?
  end

  test "does not allow the same provider account twice" do
    integration = accounts(:paid_jar).invoice_integrations.build(
      provider: "xero",
      external_account_id: invoice_integrations(:xero).external_account_id
    )

    assert_not integration.valid?
    assert_includes integration.errors[:external_account_id], "has already been taken"
  end
end

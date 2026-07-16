require "test_helper"

class InvoiceSourceTest < ActiveSupport::TestCase
  test "belongs to an account" do
    assert_equal accounts(:paid_jar), invoice_sources(:xero).account
  end

  test "has many invoices" do
    assert_includes invoice_sources(:xero).invoices, invoices(:xero_invoice)
  end

  test "has many customers" do
    assert_includes invoice_sources(:xero).customers, customers(:xero_customer)
  end

  test "requires provider and external account id" do
    source = accounts(:paid_jar).invoice_sources.build

    assert_not source.valid?
    assert_includes source.errors[:provider], "can't be blank"
    assert_includes source.errors[:external_account_id], "can't be blank"
  end

  test "defaults to pending status" do
    source = accounts(:paid_jar).invoice_sources.build(
      provider: "xero",
      external_account_id: "xero-tenant-456"
    )

    assert_predicate source, :pending?
  end

  test "knows whether it is connected" do
    assert_predicate invoice_sources(:xero), :connected?
  end

  test "encrypts OAuth tokens at rest" do
    source = Account.create!(name: "Encrypted Tokens").invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "encrypted-token-tenant",
      access_token: "secret-access-token",
      refresh_token: "secret-refresh-token"
    )

    stored_tokens = InvoiceSource.connection.select_one(
      InvoiceSource.sanitize_sql_array(
        [ "SELECT access_token, refresh_token FROM invoice_sources WHERE id = ?", source.id ]
      )
    )

    assert_equal "secret-access-token", source.reload.access_token
    assert_equal "secret-refresh-token", source.refresh_token
    refute_includes stored_tokens.fetch("access_token"), "secret-access-token"
    refute_includes stored_tokens.fetch("refresh_token"), "secret-refresh-token"
  end

  test "disconnect removes every stored token value" do
    source = Account.create!(name: "Disconnected Tokens").invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "disconnected-token-tenant",
      access_token: "access-token",
      refresh_token: "refresh-token",
      raw_token_data: { "token_type" => "Bearer" }
    )

    source.disconnect!

    assert_nil source.access_token
    assert_nil source.refresh_token
    assert_empty source.raw_token_data
  end

  test "stripe source is connected without a refresh token" do
    source = accounts(:paid_jar).invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: "acct_123"
    )

    assert_predicate source, :connected?
    assert_includes InvoiceSource.connected_for(accounts(:paid_jar)), source
  end

  test "pending stripe source is not connected" do
    source = accounts(:paid_jar).invoice_sources.build(provider: :stripe)

    assert_not_predicate source, :connected?
  end

  test "xero source is not connected without a refresh token" do
    account = Account.create!(name: "Xero Without Refresh")
    source = account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "tenant-123"
    )

    assert_not_predicate source, :connected?
    assert_not_includes InvoiceSource.connected_for(account), source
  end

  test "available sources include supported providers and current connections" do
    source = accounts(:paid_jar).invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: "acct_123",
      external_account_name: "PaymentReminder Stripe"
    )

    available_sources = InvoiceSource.available_sources_for(accounts(:paid_jar))
    xero = available_sources.find { |available_source| available_source.provider == :xero }
    stripe = available_sources.find { |available_source| available_source.provider == :stripe }

    assert_equal "Xero", xero.name
    assert_equal :new_xero_connection_path, xero.connect_path_name
    assert_equal invoice_sources(:xero), xero.connected_source

    assert_equal "Stripe", stripe.name
    assert_equal :new_stripe_connection_path, stripe.connect_path_name
    assert_equal source, stripe.connected_source
  end

  test "delegates connection and invoice sync to provider adapter" do
    source = invoice_sources(:xero)
    adapter = mock
    sync_sequence = sequence("full invoice sync")

    InvoiceSources::Xero.expects(:new).twice.with(source).returns(adapter)
    adapter.expects(:connect!).with(code: "auth-code")
    adapter.expects(:sync_invoices!).in_sequence(sync_sequence)
    Customer.any_instance.expects(:refresh_customer_segment!).once.in_sequence(sync_sequence)

    source.connect!(code: "auth-code")
    source.sync_invoices!
  end

  test "propagates a full invoice sync failure" do
    source = invoice_sources(:xero)
    adapter = mock

    InvoiceSources::Xero.expects(:new).with(source).returns(adapter)
    adapter.expects(:sync_invoices!).raises(InvoiceSources::Xero::OauthClient::Error, "provider unavailable")
    Customer.any_instance.expects(:refresh_customer_segment!).never
    assert_raises(InvoiceSources::Xero::OauthClient::Error) do
      source.sync_invoices!
    end
  end

  test "delegates an individual invoice sync to the provider adapter" do
    source = invoice_sources(:xero)
    adapter = mock

    InvoiceSources::Xero.expects(:new).with(source).returns(adapter)
    adapter.expects(:sync_invoice!).with(external_id: "invoice-123")
    Customer.any_instance.expects(:refresh_customer_segment!).once
    source.sync_invoice!(external_id: "invoice-123")
  end

  test "does not allow the same provider twice for an account" do
    source = accounts(:paid_jar).invoice_sources.build(
      provider: "xero",
      external_account_id: "different-xero-tenant"
    )

    assert_not source.valid?
    assert_includes source.errors[:provider], "has already been taken"
  end
end

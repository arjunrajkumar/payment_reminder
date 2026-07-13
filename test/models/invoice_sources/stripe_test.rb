require "test_helper"

module InvoiceSources
  class StripeTest < ActiveSupport::TestCase
    test "connect exchanges the code and stores the active account" do
      account = Account.create!(name: "New Stripe Account")
      source = account.invoice_sources.build(provider: :stripe)
      fake_client = FakeStripeClient.new

      InvoiceSources::Stripe::OauthClient.stubs(:new).returns(fake_client)

      source = InvoiceSources::Stripe.new(source).connect!(code: "auth-code")

      assert_predicate source, :persisted?
      assert_predicate source, :active?
      assert_equal "deprecated-access-token", source.access_token
      assert_nil source.refresh_token
      assert_equal "acct_123", source.external_account_id
      assert_equal "acct_123", source.external_account_name
      assert_equal false, source.provider_data["livemode"]
      assert_equal "acct_123", source.raw_token_data["stripe_user_id"]
      refute source.raw_token_data.key?("access_token")
      refute source.raw_token_data.key?("refresh_token")
      assert fake_client.exchange_code_called
    end

    test "sync_invoices stores Stripe invoices" do
      source = accounts(:paid_jar).invoice_sources.create!(
        provider: :stripe,
        status: :active,
        external_account_id: "acct_123"
      )
      fake_client = FakeStripeClient.new

      InvoiceSources::Stripe::OauthClient.stubs(:new).returns(fake_client)

      assert_difference -> { source.invoices.count }, 1 do
        InvoiceSources::Stripe.new(source).sync_invoices!
      end

      invoice = source.invoices.find_by!(external_id: "in_456")
      assert_equal "STR-456", invoice.number
      assert_equal "Example Stripe Customer", invoice.contact_name
      assert_equal "open", invoice.status
      assert_equal "USD", invoice.currency
      assert_equal BigDecimal("250.50"), invoice.total
      assert_equal BigDecimal("125.25"), invoice.amount_due
      assert_equal Date.new(2026, 7, 1), invoice.issued_on
      assert_equal Date.new(2026, 7, 31), invoice.due_on
      assert_equal Date.new(2026, 7, 15), invoice.paid_on
      assert_equal "billing@example.com", invoice.provider_data["customer_email"]
      assert fake_client.invoices_called
    end

    class FakeStripeClient
      attr_accessor :exchange_code_called, :invoices_called

      def exchange_code(code:)
        raise "unexpected code" unless code == "auth-code"

        self.exchange_code_called = true
        {
          "access_token" => "deprecated-access-token",
          "stripe_user_id" => "acct_123",
          "livemode" => false,
          "token_type" => "bearer",
          "scope" => "read_write"
        }
      end

      def invoices(stripe_account_id:)
        raise "unexpected Stripe account id" unless stripe_account_id == "acct_123"

        self.invoices_called = true
        {
          "data" => [
            {
              "id" => "in_456",
              "number" => "STR-456",
              "collection_method" => "send_invoice",
              "billing_reason" => "manual",
              "status" => "open",
              "currency" => "usd",
              "amount_due" => 25050,
              "amount_paid" => 12525,
              "amount_remaining" => 12525,
              "total" => 25050,
              "created" => Time.zone.local(2026, 7, 1).to_i,
              "due_date" => Time.zone.local(2026, 7, 31).to_i,
              "status_transitions" => {
                "paid_at" => Time.zone.local(2026, 7, 15).to_i
              },
              "customer" => "cus_123",
              "customer_name" => "Example Stripe Customer",
              "customer_email" => "billing@example.com",
              "hosted_invoice_url" => "https://invoice.stripe.com/i/in_456",
              "invoice_pdf" => "https://invoice.stripe.com/i/in_456.pdf"
            }
          ]
        }
      end
    end
  end
end

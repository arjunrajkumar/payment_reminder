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
      source = stripe_source
      fake_client = FakeStripeClient.new

      InvoiceSources::Stripe::OauthClient.stubs(:new).returns(fake_client)

      assert_difference -> { source.customers.count }, 1 do
        assert_difference -> { source.invoices.count }, 1 do
          InvoiceSources::Stripe.new(source).sync_invoices!
        end
      end

      invoice = source.invoices.find_by!(external_id: "in_456")
      customer = source.customers.find_by!(external_id: "cus_123")
      assert_equal "STR-456", invoice.number
      assert_equal "Example Stripe Customer", invoice.contact_name
      assert_equal "open", invoice.provider_status
      assert_equal "open", invoice.status
      assert_equal "USD", invoice.currency
      assert_equal BigDecimal("250.50"), invoice.total
      assert_equal BigDecimal("125.25"), invoice.amount_due
      assert_equal Date.new(2026, 7, 1), invoice.issued_on
      assert_equal Date.new(2026, 7, 31), invoice.due_on
      assert_equal Date.new(2026, 7, 15), invoice.paid_on
      assert_equal "billing@example.com", invoice.provider_data["customer_email"]
      assert_equal customer, invoice.customer
      assert_equal "Example Stripe Customer", customer.name
      assert_equal "billing@example.com", customer.email
      assert_equal Time.zone.local(2026, 7, 1), customer.details_observed_at
      assert fake_client.invoices_called
    end

    test "sync_invoices stores when Stripe marked an invoice uncollectible" do
      source = stripe_source
      marked_uncollectible_at = Time.zone.local(2026, 7, 20, 10, 30)
      fake_client = FakeStripeClient.new(
        status: "uncollectible",
        marked_uncollectible_at: marked_uncollectible_at.to_i
      )

      InvoiceSources::Stripe::InvoiceSync.new(source, client: fake_client).sync!

      invoice = source.invoices.find_by!(external_id: "in_456")
      assert_equal "uncollectible", invoice.status
      assert_equal marked_uncollectible_at.to_date, invoice.completed_on
    end

    test "sync_invoices reuses the Stripe customer for the same customer id" do
      source = stripe_source
      fake_client = FakeStripeClient.new

      InvoiceSources::Stripe::OauthClient.stubs(:new).returns(fake_client)

      InvoiceSources::Stripe.new(source).sync_invoices!

      assert_no_difference [ -> { source.customers.count }, -> { source.invoices.count } ] do
        InvoiceSources::Stripe.new(source).sync_invoices!
      end
    end

    test "a newer invoice without a customer name does not replace the persisted name" do
      source = stripe_source
      older_invoice = FakeStripeClient.new(
        invoice_id: "in_older",
        created: Time.zone.local(2026, 7, 1).to_i,
        customer_name: "Current Customer",
        customer_email: "old@example.com"
      )
      newer_invoice = FakeStripeClient.new(
        invoice_id: "in_newer",
        created: Time.zone.local(2026, 7, 2).to_i,
        customer_name: nil,
        customer_email: "new@example.com"
      )

      InvoiceSources::Stripe::InvoiceSync.new(source, client: older_invoice).sync!
      InvoiceSources::Stripe::InvoiceSync.new(source, client: newer_invoice).sync!

      customer = source.customers.find_by!(external_id: "cus_123")
      assert_equal "Current Customer", customer.name
      assert_equal "new@example.com", customer.email
      assert_equal Time.zone.local(2026, 7, 2), customer.details_observed_at
      assert_equal 2, customer.invoices.count
    end

    test "sync_invoices supports an expanded Stripe customer and prefers invoice details" do
      source = stripe_source
      fake_client = FakeStripeClient.new(
        customer: {
          "id" => "cus_expanded",
          "name" => "Expanded Customer",
          "email" => "expanded@example.com"
        },
        customer_name: "Invoice Customer",
        customer_email: "invoice@example.com"
      )

      InvoiceSources::Stripe::OauthClient.stubs(:new).returns(fake_client)

      InvoiceSources::Stripe.new(source).sync_invoices!

      invoice = source.invoices.find_by!(external_id: "in_456")
      assert_equal "cus_expanded", invoice.customer.external_id
      assert_equal "Invoice Customer", invoice.customer.name
      assert_equal "invoice@example.com", invoice.customer.email
      assert_equal "cus_expanded", invoice.contact_external_id
      assert_equal "Invoice Customer", invoice.contact_name
    end

    test "sync_invoices uses an invoice identity when Stripe omits the customer id" do
      source = stripe_source
      fake_client = FakeStripeClient.new(customer: nil)

      InvoiceSources::Stripe::OauthClient.stubs(:new).returns(fake_client)

      InvoiceSources::Stripe.new(source).sync_invoices!

      invoice = source.invoices.find_by!(external_id: "in_456")
      assert_equal "invoice:in_456", invoice.customer.external_id
      assert_equal "Example Stripe Customer", invoice.customer.name
      assert_equal "billing@example.com", invoice.customer.email
      assert_nil invoice.contact_external_id
    end

    private
      def stripe_source
        accounts(:paid_jar).invoice_sources.create!(
          provider: :stripe,
          status: :active,
          external_account_id: "acct_123"
        )
      end

    class FakeStripeClient
      attr_accessor :exchange_code_called, :invoices_called

      def initialize(
        customer: "cus_123",
        customer_name: "Example Stripe Customer",
        customer_email: "billing@example.com",
        invoice_id: "in_456",
        created: Time.zone.local(2026, 7, 1).to_i,
        status: "open",
        marked_uncollectible_at: nil
      )
        @customer = customer
        @customer_name = customer_name
        @customer_email = customer_email
        @invoice_id = invoice_id
        @created = created
        @status = status
        @marked_uncollectible_at = marked_uncollectible_at
      end

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
              "id" => @invoice_id,
              "number" => "STR-456",
              "collection_method" => "send_invoice",
              "billing_reason" => "manual",
              "status" => @status,
              "currency" => "usd",
              "amount_due" => 25050,
              "amount_paid" => 12525,
              "amount_remaining" => 12525,
              "total" => 25050,
              "created" => @created,
              "due_date" => Time.zone.local(2026, 7, 31).to_i,
              "status_transitions" => {
                "paid_at" => Time.zone.local(2026, 7, 15).to_i,
                "marked_uncollectible_at" => @marked_uncollectible_at
              }.compact,
              "customer" => @customer,
              "customer_name" => @customer_name,
              "customer_email" => @customer_email,
              "hosted_invoice_url" => "https://invoice.stripe.com/i/in_456",
              "invoice_pdf" => "https://invoice.stripe.com/i/in_456.pdf"
            }
          ]
        }
      end
    end
  end
end

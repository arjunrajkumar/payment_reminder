require "test_helper"

module InvoiceSources
  class XeroTest < ActiveSupport::TestCase
    test "connect exchanges the code and stores the active tenant" do
      account = Account.create!(name: "New Xero Account")
      source = account.invoice_sources.build(provider: :xero)
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      source = InvoiceSources::Xero.new(source).connect!(code: "auth-code")

      assert_predicate source, :persisted?
      assert_predicate source, :active?
      assert_equal "access-token", source.access_token
      assert_equal "refresh-token", source.refresh_token
      assert_equal "tenant-123", source.external_account_id
      assert_equal "PaymentReminder Demo", source.external_account_name
      assert_equal "person@example.com", source.provider_data["email"]
      assert_equal "Bearer", source.raw_token_data["token_type"]
      refute source.raw_token_data.key?("access_token")
      refute source.raw_token_data.key?("refresh_token")
      refute source.raw_token_data.key?("id_token")
      assert fake_client.exchange_code_called
      assert fake_client.connections_called
      assert fake_client.userinfo_called
    end

    test "sync_invoices stores Xero invoices" do
      source = invoice_sources(:xero)
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      assert_difference -> { source.invoices.count }, 1 do
        InvoiceSources::Xero.new(source).sync_invoices!
      end

      invoice = source.invoices.find_by!(external_id: "invoice-456")
      assert_equal "INV-456", invoice.number
      assert_equal "Example Customer", invoice.contact_name
      assert_equal "AUTHORISED", invoice.status
      assert_equal BigDecimal("250.50"), invoice.total
      assert_equal Date.new(2026, 7, 11), invoice.paid_on
      assert fake_client.invoices_called
    end

    test "refreshes an expired access token before syncing invoices" do
      source = invoice_sources(:xero)
      source.update!(access_token: "old-token", refresh_token: "old-refresh-token", expires_at: 1.minute.ago)
      fake_client = FakeXeroClient.new

      InvoiceSources::Xero::OauthClient.stubs(:new).returns(fake_client)

      InvoiceSources::Xero.new(source).sync_invoices!

      assert_equal "new-access-token", source.reload.access_token
      assert_equal "new-refresh-token", source.refresh_token
      refute source.raw_token_data.key?("access_token")
      refute source.raw_token_data.key?("refresh_token")
      assert fake_client.refresh_token_called
    end

    class FakeXeroClient
      attr_accessor :exchange_code_called, :connections_called, :userinfo_called,
        :invoices_called, :refresh_token_called

      def initialize(tenant_id: "tenant-123", tenant_name: "PaymentReminder Demo")
        @tenant_id = tenant_id
        @tenant_name = tenant_name
      end

      def exchange_code(code:)
        raise "unexpected code" unless code == "auth-code"

        self.exchange_code_called = true
        {
          "access_token" => "access-token",
          "refresh_token" => "refresh-token",
          "id_token" => "id-token",
          "token_type" => "Bearer",
          "expires_in" => 1800,
          "scope" => "openid profile email accounting.invoices.read accounting.contacts.read offline_access"
        }
      end

      def refresh_token(refresh_token:)
        raise "unexpected refresh token" unless refresh_token == "old-refresh-token"

        self.refresh_token_called = true
        {
          "access_token" => "new-access-token",
          "refresh_token" => "new-refresh-token",
          "token_type" => "Bearer",
          "expires_in" => 1800,
          "scope" => "openid profile email accounting.invoices.read accounting.contacts.read offline_access"
        }
      end

      def connections(access_token:)
        raise "unexpected access token" unless access_token == "access-token"

        self.connections_called = true
        [
          {
            "tenantId" => @tenant_id,
            "tenantName" => @tenant_name
          }
        ]
      end

      def userinfo(access_token:)
        raise "unexpected access token" unless access_token == "access-token"

        self.userinfo_called = true
        {
          "xero_userid" => "user-123",
          "email" => "person@example.com"
        }
      end

      def invoices(access_token:, tenant_id:)
        raise "unexpected access token" unless access_token.in?(%w[access-token new-access-token])
        raise "unexpected tenant id" unless tenant_id == "xero-tenant-123"

        self.invoices_called = true
        {
          "Invoices" => [
            {
              "InvoiceID" => "invoice-456",
              "InvoiceNumber" => "INV-456",
              "Type" => "ACCREC",
              "Status" => "AUTHORISED",
              "CurrencyCode" => "USD",
              "AmountDue" => "250.50",
              "AmountPaid" => "0.00",
              "Total" => "250.50",
              "DateString" => "2026-07-01",
              "DueDateString" => "2026-07-31",
              "FullyPaidOnDate" => "/Date(1783728000000+0000)/",
              "Contact" => {
                "ContactID" => "contact-456",
                "Name" => "Example Customer"
              }
            }
          ]
        }
      end
    end
  end
end

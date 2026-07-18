require "test_helper"

module InvoiceSources
  class Xero
    class OauthClientTest < ActiveSupport::TestCase
      test "authorization_url includes Xero OAuth parameters" do
        with_xero_credentials(
          client_id: "client-123",
          client_secret: "secret-123"
        ) do
          config = Configuration.new

          url = OauthClient.new(config: config).authorization_url(
            redirect_uri: "https://example.com/xero/callback",
            state: "state-123"
          )

          uri = URI(url)
          params = Rack::Utils.parse_query(uri.query)

          assert_equal "login.xero.com", uri.host
          assert_equal "/identity/connect/authorize", uri.path
          assert_equal "code", params["response_type"]
          assert_equal "client-123", params["client_id"]
          assert_equal "https://example.com/xero/callback", params["redirect_uri"]
          assert_equal Configuration::DEFAULT_SCOPES.join(" "), params["scope"]
          assert_equal "state-123", params["state"]
        end
      end

      test "invoices passes the requested Xero filter" do
        stub_request(
          :get,
          "https://api.xero.com/api.xro/2.0/Invoices?" \
            "page=1&pageSize=1000&where=Type%3D%3D%22ACCREC%22"
        ).with(
          headers: {
            "Authorization" => "Bearer access-token",
            "xero-tenant-id" => "tenant-123"
          }
        ).to_return(
          status: 200,
          body: { Invoices: [] }.to_json
        )

        payload = OauthClient.new.invoices(
          access_token: "access-token",
          tenant_id: "tenant-123",
          where: 'Type=="ACCREC"'
        )

        assert_equal [], payload.fetch("Invoices")
      end

      test "invoices combines every Xero page and preserves the filter" do
        first_page = [ { "InvoiceID" => "invoice-1" }, { "InvoiceID" => "invoice-2" } ]
        second_page = [ { "InvoiceID" => "invoice-3" } ]

        stub_request(
          :get,
          "https://api.xero.com/api.xro/2.0/Invoices?" \
            "page=1&pageSize=1000&where=Type%3D%3D%22ACCREC%22"
        ).with(
          headers: {
            "Authorization" => "Bearer access-token",
            "xero-tenant-id" => "tenant-123"
          }
        ).to_return(
          status: 200,
          body: {
            pagination: { page: 1, pageSize: 1000, pageCount: 2, itemCount: 3 },
            Invoices: first_page
          }.to_json
        )
        stub_request(
          :get,
          "https://api.xero.com/api.xro/2.0/Invoices?" \
            "page=2&pageSize=1000&where=Type%3D%3D%22ACCREC%22"
        ).with(
          headers: {
            "Authorization" => "Bearer access-token",
            "xero-tenant-id" => "tenant-123"
          }
        ).to_return(
          status: 200,
          body: {
            pagination: { page: 2, pageSize: 1000, pageCount: 2, itemCount: 3 },
            Invoices: second_page
          }.to_json
        )

        payload = OauthClient.new.invoices(
          access_token: "access-token",
          tenant_id: "tenant-123",
          where: 'Type=="ACCREC"'
        )

        assert_equal %w[invoice-1 invoice-2 invoice-3],
          payload.fetch("Invoices").pluck("InvoiceID")
      end

      test "invoices falls back to page size when Xero omits pagination metadata" do
        first_page = Array.new(OauthClient::INVOICES_PAGE_SIZE) do |index|
          { "InvoiceID" => "invoice-#{index + 1}" }
        end

        stub_request(
          :get,
          "https://api.xero.com/api.xro/2.0/Invoices?page=1&pageSize=1000"
        ).to_return(status: 200, body: { Invoices: first_page }.to_json)
        stub_request(
          :get,
          "https://api.xero.com/api.xro/2.0/Invoices?page=2&pageSize=1000"
        ).to_return(status: 200, body: { Invoices: [] }.to_json)

        payload = OauthClient.new.invoices(
          access_token: "access-token",
          tenant_id: "tenant-123"
        )

        assert_equal OauthClient::INVOICES_PAGE_SIZE, payload.fetch("Invoices").size
        assert_requested :get,
          "https://api.xero.com/api.xro/2.0/Invoices?page=2&pageSize=1000",
          times: 1
      end

      test "online_invoice retrieves the customer-facing Xero invoice URL" do
        stub_request(
          :get,
          "https://api.xero.com/api.xro/2.0/Invoices/invoice-123/OnlineInvoice"
        ).with(
          headers: {
            "Authorization" => "Bearer access-token",
            "xero-tenant-id" => "tenant-123"
          }
        ).to_return(
          status: 200,
          body: {
            OnlineInvoices: [
              { OnlineInvoiceUrl: "https://in.xero.com/invoice-123" }
            ]
          }.to_json
        )

        payload = OauthClient.new.online_invoice(
          access_token: "access-token",
          tenant_id: "tenant-123",
          invoice_id: "invoice-123"
        )

        assert_equal(
          "https://in.xero.com/invoice-123",
          payload.fetch("OnlineInvoices").first.fetch("OnlineInvoiceUrl")
        )
      end

      test "wraps Xero network failures in a retryable client error" do
        stub_request(
          :get,
          "https://api.xero.com/api.xro/2.0/Invoices/invoice-123/OnlineInvoice"
        ).to_timeout

        error = assert_raises OauthClient::Error do
          OauthClient.new.online_invoice(
            access_token: "access-token",
            tenant_id: "tenant-123",
            invoice_id: "invoice-123"
          )
        end

        assert_match "Xero request failed", error.message
      end

      private
        def with_xero_credentials(**xero)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.xero = xero
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end

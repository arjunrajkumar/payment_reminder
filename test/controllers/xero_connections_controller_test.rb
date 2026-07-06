require "test_helper"

class XeroConnectionsControllerTest < ActionDispatch::IntegrationTest
  test "connect requires a PaidJar session" do
    get new_xero_connection_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "connect redirects to Xero authorization" do
    sign_up_and_complete

    with_xero_configured do
      fake_client = FakeXeroClient.new

      AccountingIntegrations::Xero::OauthClient.stubs(:new).returns(fake_client)

      get new_xero_connection_url

      assert_redirected_to FakeXeroClient::AUTHORIZATION_URL
      assert fake_client.authorization_url_called
    end
  end

  test "connect redirects home when credentials are missing" do
    sign_up_and_complete
    AccountingIntegrations::Xero::Configuration.stubs(:new).returns(FakeXeroConfiguration.new(false))

    get new_xero_connection_url

    assert_redirected_to root_url
  end

  test "callback stores token set active tenant and invoices on the current account" do
    account = sign_up_and_complete

    with_xero_configured do
      fake_client = FakeXeroClient.new

      AccountingIntegrations::Xero::OauthClient.stubs(:new).returns(fake_client)

      get new_xero_connection_url
      get xero_callback_url, params: { code: "auth-code", state: fake_client.state }
    end

    integration = account.accounting_integrations.xero.first

    assert_redirected_to invoices_url
    assert_predicate integration, :active?
    assert_equal "access-token", integration.access_token
    assert_equal "refresh-token", integration.refresh_token
    assert_equal "tenant-123", integration.external_account_id
    assert_equal "PaidJar Demo", integration.external_account_name
    assert_equal "person@example.com", integration.provider_data["email"]
    assert_equal [ "INV-456" ], account.invoices.where(accounting_integration: integration).pluck(:number)
  end

  test "callback rejects invalid state" do
    account = sign_up_and_complete

    with_xero_configured do
      fake_client = FakeXeroClient.new

      AccountingIntegrations::Xero::OauthClient.stubs(:new).returns(fake_client)

      get new_xero_connection_url
      get xero_callback_url, params: { code: "auth-code", state: "wrong-state" }
    end

    assert_redirected_to root_url
    assert_empty account.accounting_integrations.xero
  end

  test "callback handles denied access" do
    account = sign_up_and_complete

    with_xero_configured do
      get xero_callback_url, params: { error: "access_denied" }
    end

    assert_redirected_to root_url
    assert_empty account.accounting_integrations.xero
  end

  test "callback handles xero client errors" do
    account = sign_up_and_complete

    with_xero_configured do
      fake_client = FakeXeroClient.new(error: AccountingIntegrations::Xero::OauthClient::Error.new("invalid grant"))

      AccountingIntegrations::Xero::OauthClient.stubs(:new).returns(fake_client)

      get new_xero_connection_url
      get xero_callback_url, params: { code: "auth-code", state: fake_client.state }
    end

    assert_redirected_to root_url
    assert_empty account.accounting_integrations.xero
  end

  test "destroy disconnects current account xero integration" do
    account = sign_up_and_complete
    integration = account.accounting_integrations.create!(
      provider: :xero,
      status: :active,
      external_account_id: "tenant-123",
      access_token: "access-token",
      refresh_token: "refresh-token",
      expires_at: 30.minutes.from_now
    )

    delete xero_connection_url

    assert_redirected_to root_url
    assert_predicate integration.reload, :disconnected?
    assert_nil integration.access_token
    assert_nil integration.refresh_token
  end

  test "destroy redirects when xero is not connected" do
    sign_up_and_complete

    delete xero_connection_url

    assert_redirected_to root_url
    assert_equal "Connect Xero first.", flash[:alert]
  end

  private
    def sign_up_and_complete(email_address: "owner-xero@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end

    def with_xero_configured
      AccountingIntegrations::Xero::Configuration.any_instance.stubs(:configured?).returns(true)
      yield
    end

    FakeXeroConfiguration = Struct.new(:configured?)

    class FakeXeroClient
      AUTHORIZATION_URL = "https://login.xero.com/identity/connect/authorize?fake=true"

      attr_reader :state
      attr_accessor :authorization_url_called

      def initialize(error: nil)
        @error = error
      end

      def authorization_url(state:, redirect_uri: nil)
        @state = state
        self.authorization_url_called = true
        AUTHORIZATION_URL
      end

      def exchange_code(code:, redirect_uri: nil)
        raise @error if @error
        raise "unexpected code" unless code == "auth-code"

        {
          "access_token" => "access-token",
          "refresh_token" => "refresh-token",
          "id_token" => "id-token",
          "token_type" => "Bearer",
          "expires_in" => 1800,
          "scope" => "openid profile email accounting.invoices.read accounting.contacts.read offline_access"
        }
      end

      def connections(access_token:)
        raise "unexpected access token" unless access_token == "access-token"

        [
          {
            "tenantId" => "tenant-123",
            "tenantName" => "PaidJar Demo"
          }
        ]
      end

      def userinfo(access_token:)
        raise "unexpected access token" unless access_token == "access-token"

        {
          "xero_userid" => "user-123",
          "email" => "person@example.com"
        }
      end

      def invoices(access_token:, tenant_id:)
        raise "unexpected access token" unless access_token == "access-token"
        raise "unexpected tenant id" unless tenant_id == "tenant-123"

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

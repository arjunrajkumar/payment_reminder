require "test_helper"

class StripeConnectionsControllerTest < ActionDispatch::IntegrationTest
  test "connect requires a PaymentReminder session" do
    get new_stripe_connection_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "connect redirects to Stripe authorization" do
    sign_up_and_complete

    with_stripe_configured do
      fake_client = FakeStripeClient.new

      InvoiceSources::Stripe::OauthClient.stubs(:new).returns(fake_client)

      get new_stripe_connection_url

      assert_redirected_to FakeStripeClient::AUTHORIZATION_URL
      assert fake_client.authorization_url_called
    end
  end

  test "connect redirects home when credentials are missing" do
    sign_up_and_complete
    InvoiceSources::Stripe::Configuration.stubs(:new).returns(FakeStripeConfiguration.new(false))

    get new_stripe_connection_url

    assert_redirected_to root_url
  end

  test "callback stores token set active account and invoices on the current account" do
    account = sign_up_and_complete

    with_stripe_configured do
      fake_client = FakeStripeClient.new

      InvoiceSources::Stripe::OauthClient.stubs(:new).returns(fake_client)

      get new_stripe_connection_url
      get stripe_callback_url, params: { code: "auth-code", state: fake_client.state }
    end

    source = account.invoice_sources.stripe.first

    assert_redirected_to invoices_url
    assert_predicate source, :active?
    assert_equal "deprecated-access-token", source.access_token
    assert_nil source.refresh_token
    assert_equal "acct_123", source.external_account_id
    assert_equal "acct_123", source.external_account_name
    assert_equal false, source.provider_data["livemode"]
    assert_equal [ "STR-456" ], account.invoices.where(invoice_source: source).pluck(:number)
  end

  test "callback rejects invalid state" do
    account = sign_up_and_complete

    with_stripe_configured do
      fake_client = FakeStripeClient.new

      InvoiceSources::Stripe::OauthClient.stubs(:new).returns(fake_client)

      get new_stripe_connection_url
      get stripe_callback_url, params: { code: "auth-code", state: "wrong-state" }
    end

    assert_redirected_to root_url
    assert_empty account.invoice_sources.stripe
  end

  test "callback handles denied access" do
    account = sign_up_and_complete

    with_stripe_configured do
      get stripe_callback_url, params: { error: "access_denied" }
    end

    assert_redirected_to root_url
    assert_empty account.invoice_sources.stripe
  end

  test "callback handles stripe client errors" do
    account = sign_up_and_complete

    with_stripe_configured do
      fake_client = FakeStripeClient.new(error: InvoiceSources::Stripe::OauthClient::Error.new("invalid grant"))

      InvoiceSources::Stripe::OauthClient.stubs(:new).returns(fake_client)

      get new_stripe_connection_url
      get stripe_callback_url, params: { code: "auth-code", state: fake_client.state }
    end

    assert_redirected_to root_url
    assert_empty account.invoice_sources.stripe
  end

  test "destroy disconnects current account stripe source" do
    account = sign_up_and_complete
    source = account.invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: "acct_123",
      access_token: "deprecated-access-token"
    )

    delete stripe_connection_url

    assert_redirected_to account_settings_url
    assert_predicate source.reload, :disconnected?
    assert_nil source.access_token
    assert_nil source.refresh_token
  end

  test "destroy redirects when stripe is not connected" do
    sign_up_and_complete

    delete stripe_connection_url

    assert_redirected_to new_stripe_connection_url
    assert_equal "Connect Stripe first.", flash[:alert]
  end

  private
    def sign_up_and_complete(email_address: "owner-stripe@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end

    def with_stripe_configured
      InvoiceSources::Stripe::Configuration.any_instance.stubs(:configured?).returns(true)
      yield
    end

    FakeStripeConfiguration = Struct.new(:configured?)

    class FakeStripeClient
      AUTHORIZATION_URL = "https://connect.stripe.com/oauth/authorize?fake=true"

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
          "access_token" => "deprecated-access-token",
          "stripe_user_id" => "acct_123",
          "livemode" => false,
          "token_type" => "bearer",
          "scope" => "read_write"
        }
      end

      def invoices(stripe_account_id:)
        raise "unexpected Stripe account id" unless stripe_account_id == "acct_123"

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
              "amount_paid" => 0,
              "amount_remaining" => 25050,
              "total" => 25050,
              "created" => Time.zone.local(2026, 7, 1).to_i,
              "due_date" => Time.zone.local(2026, 7, 31).to_i,
              "customer" => "cus_123",
              "customer_name" => "Example Stripe Customer",
              "customer_email" => "billing@example.com"
            }
          ]
        }
      end
    end
end

require "test_helper"

class GmailConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    OutboundEmailConnection::Gmail::Configuration.any_instance.stubs(:configured?).returns(true)
  end

  test "callback connects Gmail only to the initiating account" do
    account = sign_up_and_complete
    other_account = Account.create!(name: "Other Account")
    client = FakeGmailOauthClient.new
    OutboundEmailConnection::Gmail::OauthClient.stubs(:new).returns(client)

    get new_gmail_connection_url(script_name: account.slug)
    get gmail_callback_url(script_name: account.slug), params: { code: "auth-code", state: client.state }

    connection = account.reload.outbound_email_connection
    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_predicate connection, :active?
    assert_equal "billing@example.com", connection.connected_email
    assert_nil other_account.reload.outbound_email_connection
  end

  test "callback cannot connect Gmail through another account's state" do
    account = sign_up_and_complete(email_address: "owner-state@example.com")
    other_account = Account.create!(name: "Other State Account")
    client = FakeGmailOauthClient.new
    OutboundEmailConnection::Gmail::OauthClient.stubs(:new).returns(client)

    get new_gmail_connection_url(script_name: account.slug)
    get gmail_callback_url(script_name: other_account.slug), params: { code: "auth-code", state: client.state }

    assert_nil account.reload.outbound_email_connection
    assert_nil other_account.reload.outbound_email_connection
    assert_equal "Gmail connection could not be verified.", flash[:alert]
  end

  test "reconnection updates tokens and preserves the existing refresh token" do
    account = sign_up_and_complete(email_address: "owner-reconnect@example.com")
    connection = account.create_outbound_email_connection!(
      provider: :gmail,
      connected_email: "billing@example.com",
      access_token: "old-access",
      refresh_token: "old-refresh",
      token_expires_at: 1.minute.from_now,
      scopes: [ OutboundEmailConnection::Gmailable::SEND_SCOPE ],
      status: :active
    )
    client = FakeGmailOauthClient.new(refresh_token: nil)
    OutboundEmailConnection::Gmail::OauthClient.stubs(:new).returns(client)

    get new_gmail_connection_url(script_name: account.slug)
    get gmail_callback_url(script_name: account.slug), params: { code: "auth-code", state: client.state }

    assert_equal "access-token", connection.reload.access_token
    assert_equal "old-refresh", connection.refresh_token
  end

  test "disconnect disables reminders and removes usable credentials" do
    account = sign_up_and_complete(email_address: "owner-disconnect@example.com")
    connection = connect_gmail(account)
    account.update!(automatic_invoice_reminders_enabled: true)

    delete gmail_connection_url(script_name: account.slug)

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_not_predicate account.reload, :automatic_invoice_reminders_enabled?
    assert_predicate connection.reload, :disconnected?
    assert_nil connection.access_token
    assert_nil connection.refresh_token
  end

  test "test action sends through Gmail to the current identity" do
    account = sign_up_and_complete(email_address: "owner-test-email@example.com")
    connect_gmail(account)
    delivery = mock
    delivery.expects(:deliver).with do |message|
      message.to == [ "owner-test-email@example.com" ] &&
        message.subject == "PaymentReminder Gmail connection test"
    end.returns("test-message-id")
    OutboundEmailConnection::Delivery.stubs(:new).returns(delivery)

    post test_gmail_connection_url(script_name: account.slug)

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Test email sent.", flash[:notice]
  end

  private
    def sign_up_and_complete(email_address: "owner-gmail@example.com")
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

      Identity.find_by!(email_address:).accounts.first
    end

    def connect_gmail(account)
      account.build_outbound_email_connection.connect_gmail!(
        email: "billing@example.com",
        name: "Billing Team",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 1.hour.from_now,
        scopes: [ "email", "profile", OutboundEmailConnection::Gmailable::SEND_SCOPE ]
      )
    end

    class FakeGmailOauthClient
      AUTHORIZATION_URL = "https://accounts.google.test/authorize"

      attr_reader :state

      def initialize(refresh_token: "refresh-token")
        @refresh_token = refresh_token
      end

      def authorization_url(state:, redirect_uri:)
        @state = state
        AUTHORIZATION_URL
      end

      def exchange_code(code:, redirect_uri:)
        raise "unexpected code" unless code == "auth-code"

        {
          "access_token" => "access-token",
          "refresh_token" => @refresh_token,
          "expires_in" => 3600,
          "scope" => "email profile #{OutboundEmailConnection::Gmailable::SEND_SCOPE}"
        }
      end

      def userinfo(access_token:)
        raise "unexpected token" unless access_token == "access-token"

        { "email" => "billing@example.com", "name" => "Billing Team" }
      end
    end
end

require "test_helper"

class XeroConnectionsControllerTest < ActionDispatch::IntegrationTest
  test "connect redirects to Xero authorization" do
    with_xero_env do
      fake_client = FakeXeroClient.new

      Xero::OauthClient.stubs(:new).returns(fake_client)

      get new_xero_connection_url

      assert_redirected_to FakeXeroClient::AUTHORIZATION_URL
      assert fake_client.authorization_url_called
    end
  end

  test "connect redirects home when credentials are missing" do
    Xero::Configuration.stubs(:new).returns(FakeXeroConfiguration.new(false))

    get new_xero_connection_url

    assert_redirected_to root_url
  end

  test "callback stores token set and active tenant" do
    with_xero_env do
      fake_client = FakeXeroClient.new

      Xero::OauthClient.stubs(:new).returns(fake_client)

      get new_xero_connection_url
      get xero_callback_url, params: { code: "auth-code", state: fake_client.state }
    end

    connection = XeroConnection.current

    assert_redirected_to xero_connection_url
    assert_equal "access-token", connection.access_token
    assert_equal "refresh-token", connection.refresh_token
    assert_equal "tenant-123", connection.tenant_id
    assert_equal "PaidJar Demo", connection.tenant_name
    assert_equal "person@example.com", connection.email
  end

  test "callback rejects invalid state" do
    with_xero_env do
      fake_client = FakeXeroClient.new

      Xero::OauthClient.stubs(:new).returns(fake_client)

      get new_xero_connection_url
      get xero_callback_url, params: { code: "auth-code", state: "wrong-state" }
    end

    assert_redirected_to root_url
    assert_nil XeroConnection.current
  end

  test "callback handles denied access" do
    with_xero_env do
      get xero_callback_url, params: { error: "access_denied" }
    end

    assert_redirected_to root_url
    assert_nil XeroConnection.current
  end

  test "callback handles xero client errors" do
    with_xero_env do
      fake_client = FakeXeroClient.new(error: Xero::OauthClient::Error.new("invalid grant"))

      Xero::OauthClient.stubs(:new).returns(fake_client)

      get new_xero_connection_url
      get xero_callback_url, params: { code: "auth-code", state: fake_client.state }
    end

    assert_redirected_to root_url
    assert_nil XeroConnection.current
  end

  test "destroy removes current connection" do
    XeroConnection.create!(
      access_token: "access-token",
      refresh_token: "refresh-token",
      token_type: "Bearer",
      expires_at: 30.minutes.from_now
    )

    delete xero_connection_url

    assert_redirected_to root_url
    assert_nil XeroConnection.current
  end

  private

  def with_xero_env
    with_env(
      "XERO_CLIENT_ID" => "client-123",
      "XERO_CLIENT_SECRET" => "secret-123",
      "XERO_SCOPES" => nil
    ) do
      yield
    end
  end

  def with_env(values)
    previous_values = values.to_h { |key, _value| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
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
        "scope" => "openid profile email offline_access"
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
  end
end

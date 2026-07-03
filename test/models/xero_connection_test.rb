require "test_helper"

class XeroConnectionTest < ActiveSupport::TestCase
  test "from_oauth exchanges the code and stores the active tenant" do
    fake_client = FakeXeroClient.new

    Xero::OauthClient.stubs(:new).returns(fake_client)

    connection = XeroConnection.from_oauth!(code: "auth-code")

    assert_equal "access-token", connection.access_token
    assert_equal "refresh-token", connection.refresh_token
    assert_equal "tenant-123", connection.tenant_id
    assert_equal "PaidJar Demo", connection.tenant_name
    assert_equal "person@example.com", connection.email
    assert fake_client.exchange_code_called
    assert fake_client.connections_called
    assert fake_client.userinfo_called
  end

  class FakeXeroClient
    attr_accessor :exchange_code_called, :connections_called, :userinfo_called

    def exchange_code(code:)
      raise "unexpected code" unless code == "auth-code"

      self.exchange_code_called = true
      {
        "access_token" => "access-token",
        "refresh_token" => "refresh-token",
        "id_token" => "id-token",
        "token_type" => "Bearer",
        "expires_in" => 1800,
        "scope" => "openid profile email accounting.invoices.read offline_access"
      }
    end

    def connections(access_token:)
      raise "unexpected access token" unless access_token == "access-token"

      self.connections_called = true
      [
        {
          "tenantId" => "tenant-123",
          "tenantName" => "PaidJar Demo"
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
  end
end

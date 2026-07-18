require "test_helper"

class OutboundEmailConnectionTest < ActiveSupport::TestCase
  test "allows only one outbound connection per account" do
    account = Account.create!(name: "Unique Connection Account")

    account.create_outbound_email_connection!(gmail_attributes)
    duplicate = OutboundEmailConnection.new(gmail_attributes.merge(account:))

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:account_id], "has already been taken"
  end

  test "encrypts Gmail tokens at rest" do
    connection = Account.create!(name: "Encrypted Connection Account")
      .create_outbound_email_connection!(gmail_attributes)
    stored_tokens = ApplicationRecord.connection.select_one(<<~SQL.squish)
      SELECT access_token, refresh_token
      FROM outbound_email_connections
      WHERE id = #{connection.id}
    SQL

    assert_equal "access-token", connection.access_token
    assert_equal "refresh-token", connection.refresh_token
    refute_equal "access-token", stored_tokens.fetch("access_token")
    refute_equal "refresh-token", stored_tokens.fetch("refresh_token")
  end

  test "reconnection preserves the existing refresh token when Google omits it" do
    connection = Account.create!(name: "Reconnect Account")
      .create_outbound_email_connection!(gmail_attributes)

    connection.connect_gmail!(
      email: "billing@example.com",
      name: "Billing Team",
      access_token: "new-access-token",
      refresh_token: nil,
      expires_at: 1.hour.from_now,
      scopes: [ "email", OutboundEmailConnection::Gmailable::SEND_SCOPE ]
    )

    assert_equal "new-access-token", connection.access_token
    assert_equal "refresh-token", connection.refresh_token
    assert_predicate connection, :active?
  end

  test "refreshes an access token that expires within five minutes" do
    connection = Account.create!(name: "Refresh Account").create_outbound_email_connection!(
      gmail_attributes.merge(token_expires_at: 4.minutes.from_now)
    )
    oauth_client = mock
    oauth_client.expects(:refresh_token).with(refresh_token: "refresh-token").returns(
      "access_token" => "fresh-token",
      "expires_in" => 3600
    )

    connection.refresh_gmail_access_token_if_needed!(oauth_client:)

    assert_equal "fresh-token", connection.access_token
    assert_in_delta 1.hour.from_now, connection.token_expires_at, 1.second
  end

  test "does not reuse a refresh token for a different Gmail address" do
    connection = Account.create!(name: "Changed Gmail Account")
      .create_outbound_email_connection!(gmail_attributes)

    assert_raises ActiveRecord::RecordInvalid do
      connection.connect_gmail!(
        email: "different@example.com",
        name: "Different User",
        access_token: "different-access-token",
        refresh_token: nil,
        expires_at: 1.hour.from_now,
        scopes: [ OutboundEmailConnection::Gmailable::SEND_SCOPE ]
      )
    end

    assert_equal "billing@example.com", connection.reload.connected_email
    assert_equal "refresh-token", connection.refresh_token
  end

  private
    def gmail_attributes
      {
        provider: :gmail,
        connected_email: "billing@example.com",
        provider_display_name: "Billing Team",
        access_token: "access-token",
        refresh_token: "refresh-token",
        token_expires_at: 1.hour.from_now,
        scopes: [ "email", OutboundEmailConnection::Gmailable::SEND_SCOPE ],
        status: :active
      }
    end
end

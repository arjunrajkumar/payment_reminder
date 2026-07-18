require "test_helper"

class OutboundEmailConnection::Gmail::OauthStateTest < ActiveSupport::TestCase
  test "verifies the initiating account and browser nonce" do
    account = accounts(:paid_jar)
    token = OutboundEmailConnection::Gmail::OauthState.issue(account:, nonce: "browser-nonce")

    assert OutboundEmailConnection::Gmail::OauthState.valid?(token, account:, nonce: "browser-nonce")
    refute OutboundEmailConnection::Gmail::OauthState.valid?(token, account: Account.create!(name: "Other"), nonce: "browser-nonce")
    refute OutboundEmailConnection::Gmail::OauthState.valid?(token, account:, nonce: "different-nonce")
    refute OutboundEmailConnection::Gmail::OauthState.valid?("tampered", account:, nonce: "browser-nonce")
  end
end

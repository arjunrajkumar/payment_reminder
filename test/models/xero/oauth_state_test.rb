require "test_helper"

class Xero::OauthStateTest < ActiveSupport::TestCase
  test "binds a signed state to its flow and browser nonce" do
    token = Xero::OauthState.issue(flow: :signup, browser_nonce: "browser-nonce")

    assert Xero::OauthState.valid?(token, flow: :signup, browser_nonce: "browser-nonce")
    refute Xero::OauthState.valid?(token, flow: :signin, browser_nonce: "browser-nonce")
    refute Xero::OauthState.valid?(token, flow: :signup, browser_nonce: "different-nonce")
    refute Xero::OauthState.valid?("tampered", flow: :signup, browser_nonce: "browser-nonce")
  end

  test "expires signed state" do
    token = Xero::OauthState.issue(flow: :signup, browser_nonce: "browser-nonce")

    travel 16.minutes do
      refute Xero::OauthState.valid?(token, flow: :signup, browser_nonce: "browser-nonce")
    end
  end
end

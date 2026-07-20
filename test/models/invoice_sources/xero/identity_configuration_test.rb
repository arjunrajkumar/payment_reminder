require "test_helper"

module InvoiceSources
  class Xero
    class IdentityConfigurationTest < ActiveSupport::TestCase
      test "identity callback URIs are derived from the trusted host" do
        configuration = Configuration.new(host: "https://app.example.com/")

        assert_equal "https://app.example.com/signup/xero/callback", configuration.signup_redirect_uri
        assert_equal "https://app.example.com/session/xero/callback", configuration.session_redirect_uri
      end

      test "sign-in requests only identity scopes" do
        assert_equal "openid profile email", Configuration.new.identity_scopes
      end
    end
  end
end

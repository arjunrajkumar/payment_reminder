require "test_helper"

module Xero
  class ConfigurationTest < ActiveSupport::TestCase
    test "default scopes request identity and read-only accounting access" do
      config = Configuration.new(env: {})

      assert_equal "openid profile email accounting.invoices.read offline_access", config.scopes
    end

    test "redirect uri can be configured from the environment" do
      config = Configuration.new(env: { "XERO_REDIRECT_URI" => "https://example.com/xero/callback" })

      assert_equal "https://example.com/xero/callback", config.redirect_uri
    end
  end
end

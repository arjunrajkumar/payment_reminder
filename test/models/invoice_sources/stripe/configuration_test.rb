require "test_helper"

module InvoiceSources
  class Stripe
    class ConfigurationTest < ActiveSupport::TestCase
      test "default scope requests account access" do
        with_stripe_credentials(client_id: "ca_123", secret_key: "sk_test_123") do
          config = Configuration.new

          assert_equal "read_write", config.scope
        end
      end

      test "redirect uri can be configured from credentials" do
        with_stripe_credentials(redirect_uri: "https://example.com/stripe/callback") do
          config = Configuration.new

          assert_equal "https://example.com/stripe/callback", config.redirect_uri
        end
      end

      test "credentials determine whether Stripe is configured" do
        with_stripe_credentials(
          client_id: "ca_123",
          secret_key: "sk_test_123",
          redirect_uri: "https://example.com/stripe/callback"
        ) do
          assert_predicate Configuration.new, :configured?
        end

        with_stripe_credentials(client_id: "ca_123", secret_key: "sk_test_123") do
          assert_not_predicate Configuration.new, :configured?
        end
      end

      test "webhook signing secrets can be configured as one secret or many" do
        with_stripe_credentials(webhook_signing_secret: "whsec_one") do
          assert_equal [ "whsec_one" ], Configuration.new.webhook_signing_secrets
        end

        with_stripe_credentials(webhook_signing_secrets: [ "whsec_old", "whsec_new" ]) do
          assert_equal [ "whsec_old", "whsec_new" ], Configuration.new.webhook_signing_secrets
        end
      end

      private
        def with_stripe_credentials(**stripe)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.stripe = stripe
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end

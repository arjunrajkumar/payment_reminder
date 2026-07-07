require "test_helper"

module InvoiceSources
  class Stripe
    class WebhookEventTest < ActiveSupport::TestCase
      setup do
        @source = accounts(:paid_jar).invoice_sources.create!(
          provider: :stripe,
          status: :active,
          external_account_id: "acct_123"
        )
      end

      test "normalizes verified invoice events for connected Stripe sources" do
        payload = stripe_payload.to_json

        with_stripe_credentials(webhook_signing_secret: "whsec_test") do
          events = WebhookEvent.from_request(
            payload: payload,
            signature: stripe_signature(payload, "whsec_test")
          )

          assert_equal 1, events.size
          event = events.first

          assert_equal @source, event.fetch(:invoice_source)
          assert_equal :stripe, event.fetch(:provider)
          assert_equal "evt_123", event.fetch(:provider_event_id)
          assert_equal "invoice.updated", event.fetch(:event_type)
          assert_equal "invoice", event.fetch(:resource_type)
          assert_equal "in_123", event.fetch(:resource_id)
          assert_equal Time.zone.at(1_788_888_800), event.fetch(:occurred_at)
        end
      end

      test "ignores non invoice events" do
        payload = stripe_payload(type: "customer.updated").to_json

        with_stripe_credentials(webhook_signing_secret: "whsec_test") do
          events = WebhookEvent.from_request(
            payload: payload,
            signature: stripe_signature(payload, "whsec_test")
          )

          assert_empty events
        end
      end

      test "rejects invalid signatures" do
        payload = stripe_payload.to_json

        with_stripe_credentials(webhook_signing_secret: "whsec_test") do
          assert_raises WebhookEvent::Error do
            WebhookEvent.from_request(payload: payload, signature: stripe_signature(payload, "wrong-secret"))
          end
        end
      end

      test "accepts any configured signing secret" do
        payload = stripe_payload.to_json

        with_stripe_credentials(webhook_signing_secrets: [ "old_secret", "new_secret" ]) do
          events = WebhookEvent.from_request(
            payload: payload,
            signature: stripe_signature(payload, "new_secret")
          )

          assert_equal 1, events.size
          assert_equal "evt_123", events.first.fetch(:provider_event_id)
        end
      end

      test "rejects signatures with future timestamps outside tolerance" do
        payload = stripe_payload.to_json

        with_stripe_credentials(webhook_signing_secret: "whsec_test") do
          assert_raises WebhookEvent::Error do
            WebhookEvent.from_request(
              payload: payload,
              signature: stripe_signature(payload, "whsec_test", timestamp: 10.minutes.from_now.to_i)
            )
          end
        end
      end

      private
        def stripe_payload(type: "invoice.updated")
          {
            id: "evt_123",
            type: type,
            account: "acct_123",
            created: 1_788_888_800,
            data: {
              object: {
                id: "in_123",
                object: "invoice"
              }
            }
          }
        end

        def stripe_signature(payload, secret, timestamp: Time.current.to_i)
          digest = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")
          "t=#{timestamp},v1=#{digest}"
        end

        def with_stripe_credentials(**stripe)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.stripe = stripe
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end

require "test_helper"

module InvoiceSources
  class Xero
    class WebhookEventTest < ActiveSupport::TestCase
      test "normalizes each verified invoice event for connected Xero sources" do
        payload = xero_payload.to_json

        with_xero_credentials(webhook_signing_key: "xero-secret") do
          events = WebhookEvent.from_request(
            payload: payload,
            signature: xero_signature(payload, "xero-secret")
          )

          assert_equal 1, events.size
          event = events.first

          assert_equal invoice_sources(:xero), event.fetch(:invoice_source)
          assert_equal :xero, event.fetch(:provider)
          assert_equal "UPDATE", event.fetch(:event_type)
          assert_equal "invoice", event.fetch(:resource_type)
          assert_equal "invoice-123", event.fetch(:resource_id)
          assert_equal Time.zone.parse("2026-07-07T10:00:00Z"), event.fetch(:occurred_at)
          assert_includes event.fetch(:provider_event_id), "xero-tenant-123:INVOICE:UPDATE:invoice-123"
        end
      end

      test "ignores non invoice events" do
        payload = xero_payload(event_category: "CONTACT", resource_id: "contact-123").to_json

        with_xero_credentials(webhook_signing_key: "xero-secret") do
          events = WebhookEvent.from_request(
            payload: payload,
            signature: xero_signature(payload, "xero-secret")
          )

          assert_empty events
        end
      end

      test "rejects invalid signatures" do
        payload = xero_payload.to_json

        with_xero_credentials(webhook_signing_key: "xero-secret") do
          assert_raises WebhookEvent::Error do
            WebhookEvent.from_request(payload: payload, signature: xero_signature(payload, "wrong-secret"))
          end
        end
      end

      private
        def xero_payload(event_category: "INVOICE", resource_id: "invoice-123")
          {
            events: [
              {
                resourceUrl: "https://api.xero.com/api.xro/2.0/Invoices/#{resource_id}",
                resourceId: resource_id,
                tenantId: "xero-tenant-123",
                tenantType: "ORGANISATION",
                eventCategory: event_category,
                eventType: "UPDATE",
                eventDateUtc: "2026-07-07T10:00:00Z"
              }
            ],
            firstEventSequence: 10,
            lastEventSequence: 10,
            entropy: "abc123"
          }
        end

        def xero_signature(payload, secret)
          Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, payload))
        end

        def with_xero_credentials(**xero)
          credentials = ActiveSupport::OrderedOptions.new
          credentials.xero = xero
          Rails.application.stubs(:credentials).returns(credentials)
          yield
        end
    end
  end
end

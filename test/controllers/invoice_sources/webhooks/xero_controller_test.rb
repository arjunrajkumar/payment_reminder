require "test_helper"

module InvoiceSources
  module Webhooks
    class XeroControllerTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      teardown do
        clear_enqueued_jobs
        clear_performed_jobs
      end

      test "creates and enqueues each verified invoice event" do
        payload = xero_payload.to_json

        with_xero_credentials(webhook_signing_key: "xero-secret") do
          assert_difference -> { InvoiceSources::Webhooks::Event.count }, 2 do
            assert_enqueued_jobs 2, only: InvoiceSources::Webhooks::ProcessJob do
              post invoice_sources_webhooks_xero_url,
                params: payload,
                headers: json_headers("X-Xero-Signature" => xero_signature(payload, "xero-secret"))
            end
          end
        end

        assert_response :ok
        assert_equal %w[invoice-123 invoice-456], InvoiceSources::Webhooks::Event.order(:created_at).last(2).map(&:resource_id)
      end

      test "does not enqueue duplicate events" do
        payload = xero_payload.to_json

        with_xero_credentials(webhook_signing_key: "xero-secret") do
          post invoice_sources_webhooks_xero_url,
            params: payload,
            headers: json_headers("X-Xero-Signature" => xero_signature(payload, "xero-secret"))

          assert_no_difference -> { InvoiceSources::Webhooks::Event.count } do
            assert_no_enqueued_jobs do
              post invoice_sources_webhooks_xero_url,
                params: payload,
                headers: json_headers("X-Xero-Signature" => xero_signature(payload, "xero-secret"))
            end
          end
        end

        assert_response :ok
      end

      test "rejects invalid signatures" do
        payload = xero_payload.to_json

        with_xero_credentials(webhook_signing_key: "xero-secret") do
          assert_no_difference -> { InvoiceSources::Webhooks::Event.count } do
            post invoice_sources_webhooks_xero_url,
              params: payload,
              headers: json_headers("X-Xero-Signature" => xero_signature(payload, "wrong-secret"))
          end
        end

        assert_response :unauthorized
      end

      private
        def xero_payload
          {
            events: [
              xero_event("invoice-123"),
              xero_event("invoice-456")
            ],
            firstEventSequence: 10,
            lastEventSequence: 11,
            entropy: "abc123"
          }
        end

        def xero_event(resource_id)
          {
            resourceUrl: "https://api.xero.com/api.xro/2.0/Invoices/#{resource_id}",
            resourceId: resource_id,
            tenantId: "xero-tenant-123",
            tenantType: "ORGANISATION",
            eventCategory: "INVOICE",
            eventType: "UPDATE",
            eventDateUtc: "2026-07-07T10:00:00Z"
          }
        end

        def xero_signature(payload, secret)
          Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, payload))
        end

        def json_headers(headers = {})
          headers.merge("Content-Type" => "application/json")
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

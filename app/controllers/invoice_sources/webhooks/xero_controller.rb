module InvoiceSources
  module Webhooks
    class XeroController < ApplicationController
      def create
        queue_events(verified_events)
        head :ok
      rescue InvoiceSources::Xero::WebhookEvent::Error => error
        log_webhook_error("Xero", error)
        head :unauthorized
      end

      private
        def verified_events
          InvoiceSources::Xero::WebhookEvent.from_request(
            payload: request.body.read,
            signature: request.headers["X-Xero-Signature"] || request.headers["x-xero-signature"]
          )
        end
    end
  end
end

module InvoiceSources
  module Webhooks
    class StripeController < ApplicationController
      def create
        queue_events(verified_events)
        head :ok
      rescue InvoiceSources::Stripe::WebhookEvent::Error => error
        log_webhook_error("Stripe", error)
        head :bad_request
      end

      private
        def verified_events
          InvoiceSources::Stripe::WebhookEvent.from_request(
            payload: request.body.read,
            signature: request.headers["Stripe-Signature"]
          )
        end
    end
  end
end

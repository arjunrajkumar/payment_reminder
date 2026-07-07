module InvoiceSources
  module Webhooks
    class ApplicationController < ActionController::API
      private
        def queue_events(events)
          events.each { |event| queue_event(event) }
        end

        def queue_event(attributes)
          event, created = InvoiceSources::Webhooks::Event.record(attributes)
          InvoiceSources::Webhooks::ProcessJob.perform_later(event) if created
        end

        def log_webhook_error(provider, error)
          logger.warn "#{provider} webhook rejected: #{error.message}"
        end
    end
  end
end

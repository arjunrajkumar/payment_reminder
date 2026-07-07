require "base64"
require "json"
require "openssl"

module InvoiceSources
  class Xero
    class WebhookEvent
      class Error < StandardError; end

      INVOICE_EVENT_CATEGORY = "INVOICE"
      INVOICE_EVENT_TYPES = %w[CREATE UPDATE].freeze

      def self.from_request(payload:, signature:, config: Configuration.new)
        new(payload: payload, signature: signature, config: config).events
      end

      def initialize(payload:, signature:, config: Configuration.new)
        @payload = payload
        @signature = signature
        @config = config
      end

      def events
        raw_events.flat_map do |event|
          next [] unless invoice_event?(event)

          invoice_sources_for(event).map do |source|
            {
              invoice_source: source,
              provider: :xero,
              provider_event_id: provider_event_id_for(event),
              event_type: event.fetch("eventType"),
              resource_type: "invoice",
              resource_id: event.fetch("resourceId"),
              occurred_at: parse_time(event["eventDateUtc"]),
              payload: payload_hash.merge("event" => event)
            }
          end
        end
      end

      private
        attr_reader :payload, :signature, :config

        def payload_hash
          @payload_hash ||= begin
            verify_signature!
            JSON.parse(payload)
          rescue JSON::ParserError
            raise Error, "Xero sent an invalid JSON payload."
          end
        end

        def verify_signature!
          raise Error, "Xero webhook signing key is not configured." if config.webhook_signing_key.blank?
          raise Error, "Xero signature is missing." if signature.blank?
          raise Error, "Xero signature does not match." unless secure_compare(signature, expected_signature)
        end

        def expected_signature
          @expected_signature ||= Base64.strict_encode64(
            OpenSSL::HMAC.digest("SHA256", config.webhook_signing_key, payload)
          )
        end

        def secure_compare(left, right)
          left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
        end

        def raw_events
          Array(payload_hash.fetch("events", []))
        end

        def invoice_event?(event)
          event["eventCategory"].to_s.casecmp?(INVOICE_EVENT_CATEGORY) &&
            event["eventType"].to_s.upcase.in?(INVOICE_EVENT_TYPES) &&
            event["resourceId"].present? &&
            event["tenantId"].present?
        end

        def invoice_sources_for(event)
          InvoiceSource.where(provider: :xero, external_account_id: event.fetch("tenantId")).select(&:connected?)
        end

        def provider_event_id_for(event)
          [
            event["tenantId"],
            event["eventCategory"],
            event["eventType"],
            event["resourceId"],
            event["eventDateUtc"],
            payload_hash["firstEventSequence"],
            payload_hash["lastEventSequence"]
          ].join(":")
        end

        def parse_time(value)
          Time.zone.parse(value.to_s) if value.present?
        rescue ArgumentError
          nil
        end
    end
  end
end

require "json"
require "stripe"

module InvoiceSources
  class Stripe
    class WebhookEvent
      class Error < StandardError; end

      TIMESTAMP_TOLERANCE = 5.minutes
      INVOICE_EVENT_TYPES = %w[
        invoice.created
        invoice.updated
        invoice.finalized
        invoice.paid
        invoice.voided
        invoice.marked_uncollectible
      ].freeze

      def self.from_request(payload:, signature:, config: Configuration.new)
        new(payload: payload, signature: signature, config: config).events
      end

      def initialize(payload:, signature:, config: Configuration.new)
        @payload = payload
        @signature = signature
        @config = config
      end

      def events
        return [] unless invoice_event?
        return [] if stripe_account_id.blank? || invoice_id.blank?

        invoice_sources.map do |source|
          {
            invoice_source: source,
            provider: :stripe,
            provider_event_id: event.id,
            event_type: event.type,
            resource_type: "invoice",
            resource_id: invoice_id,
            occurred_at: occurred_at,
            payload: payload_hash
          }
        end
      end

      private
        attr_reader :payload, :signature, :config

        def event
          @event ||= begin
            verify_event!
          rescue ::Stripe::SignatureVerificationError => error
            raise Error, error.message
          rescue JSON::ParserError
            raise Error, "Stripe sent an invalid JSON payload."
          end
        end

        def verify_event!
          raise Error, "Stripe webhook signing secret is not configured." if signing_secrets.empty?
          raise Error, "Stripe signature is missing." if signature.blank?
          raise Error, "Stripe signature timestamp is outside the allowed tolerance." if timestamp_outside_tolerance?

          signing_secrets.each_with_index do |secret, index|
            return ::Stripe::Webhook.construct_event(payload, signature, secret.to_s)
          rescue ::Stripe::SignatureVerificationError
            raise if index == signing_secrets.length - 1
          end
        end

        def timestamp_outside_tolerance?
          signature_time = parsed_signature_timestamp
          signature_time.present? && signature_time > TIMESTAMP_TOLERANCE.from_now
        end

        def parsed_signature_timestamp
          Time.zone.at(Integer(signature_timestamp)) if signature_timestamp.present?
        rescue ArgumentError
          nil
        end

        def signature_timestamp
          signature.to_s.split(",").filter_map do |part|
            key, value = part.split("=", 2)
            value if key == "t"
          end.first
        end

        def signing_secrets
          config.webhook_signing_secrets
        end

        def invoice_event?
          event.type.in?(INVOICE_EVENT_TYPES)
        end

        def invoice_id
          event.data.object.id
        end

        def stripe_account_id
          event.account
        end

        def invoice_sources
          InvoiceSource.where(provider: :stripe, external_account_id: stripe_account_id).select(&:connected?)
        end

        def occurred_at
          Time.zone.at(event.created.to_i) if event.created.present?
        end

        def payload_hash
          event.to_hash.deep_stringify_keys
        end
    end
  end
end

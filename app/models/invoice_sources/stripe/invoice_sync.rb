require "bigdecimal"

module InvoiceSources
  class Stripe
    class InvoiceSync
      def initialize(source, client: OauthClient.new)
        @source = source
        @client = client
      end

      def sync!
        payload = client.invoices(stripe_account_id: source.external_account_id)

        Array(payload.fetch("data", [])).each do |invoice_payload|
          sync_invoice!(invoice_payload)
        end

        source.update!(status: :active, last_synced_at: Time.current, last_error: nil)
      rescue OauthClient::Error => error
        source.update!(status: :error, last_error: error.message)
        raise
      end

      def sync_invoice_by_id!(external_id)
        payload = client.invoice(stripe_account_id: source.external_account_id, invoice_id: external_id)
        sync_invoice!(payload)
        source.update!(status: :active, last_synced_at: Time.current, last_error: nil)
      rescue OauthClient::Error => error
        source.update!(status: :error, last_error: error.message)
        raise
      end

      private
        attr_reader :source, :client

        def sync_invoice!(payload)
          invoice = source.invoices.find_or_initialize_by(
            account: source.account,
            external_id: payload.fetch("id")
          )

          invoice.update!(
            number: payload["number"].presence || payload.fetch("id"),
            invoice_type: payload["collection_method"],
            status: payload["status"],
            currency: payload["currency"].to_s.upcase,
            amount_due: money_from_cents(payload["amount_remaining"] || payload["amount_due"]),
            amount_paid: money_from_cents(payload["amount_paid"]),
            total: money_from_cents(payload["total"]),
            issued_on: date_from_timestamp(payload["created"]),
            due_on: date_from_timestamp(payload["due_date"]),
            contact_external_id: customer_id(payload),
            contact_name: contact_name(payload),
            provider_data: {
              billing_reason: payload["billing_reason"],
              collection_method: payload["collection_method"],
              customer_email: payload["customer_email"],
              hosted_invoice_url: payload["hosted_invoice_url"],
              invoice_pdf: payload["invoice_pdf"],
              amount_due_cents: payload["amount_due"],
              amount_remaining_cents: payload["amount_remaining"]
            }.compact,
            raw_data: payload,
            synced_at: Time.current
          )
        end

        def money_from_cents(value)
          return if value.nil?

          BigDecimal(value.to_s) / 100
        end

        def date_from_timestamp(value)
          Time.zone.at(value.to_i).to_date if value.present?
        end

        def customer_id(payload)
          customer = payload["customer"]
          customer.is_a?(Hash) ? customer["id"] : customer
        end

        def contact_name(payload)
          payload["customer_name"].presence || payload["customer_email"].presence || customer_id(payload)
        end
    end
  end
end

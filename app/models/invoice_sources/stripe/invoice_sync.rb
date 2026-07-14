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
          invoice_external_id = payload.fetch("id")

          Invoice.transaction do
            customer = Customer.sync_from_provider!(
              invoice_source: source,
              external_id: customer_id(payload).presence || "invoice:#{invoice_external_id}",
              name: customer_name(payload),
              email: customer_email(payload),
              observed_at: time_from_timestamp(payload["created"])
            )
            invoice = source.invoices.find_or_initialize_by(
              account: source.account,
              external_id: invoice_external_id
            )

            invoice.update!(
              customer: customer,
              number: payload["number"].presence || invoice_external_id,
              invoice_type: payload["collection_method"],
              provider_status: payload["status"],
              status: InvoiceStatus.normalize(payload["status"]),
              currency: payload["currency"].to_s.upcase,
              amount_due: money_from_cents(payload["amount_remaining"] || payload["amount_due"]),
              amount_paid: money_from_cents(payload["amount_paid"]),
              total: money_from_cents(payload["total"]),
              issued_on: date_from_timestamp(payload["created"]),
              due_on: date_from_timestamp(payload["due_date"]),
              paid_on: date_from_timestamp(payload.dig("status_transitions", "paid_at")),
              contact_external_id: customer_id(payload),
              contact_name: customer_display_name(payload),
              provider_data: {
                billing_reason: payload["billing_reason"],
                collection_method: payload["collection_method"],
                customer_email: customer_email(payload),
                hosted_invoice_url: payload["hosted_invoice_url"],
                invoice_pdf: payload["invoice_pdf"],
                amount_due_cents: payload["amount_due"],
                amount_remaining_cents: payload["amount_remaining"]
              }.compact,
              raw_data: payload,
              synced_at: Time.current
            )
          end
        end

        def money_from_cents(value)
          return if value.nil?

          BigDecimal(value.to_s) / 100
        end

        def date_from_timestamp(value)
          time_from_timestamp(value)&.to_date
        end

        def time_from_timestamp(value)
          Time.zone.at(value.to_i) if value.present?
        end

        def customer_id(payload)
          customer = payload["customer"]
          customer.is_a?(Hash) ? customer["id"] : customer
        end

        def customer_name(payload)
          payload["customer_name"].presence ||
            expanded_customer(payload)["name"].presence
        end

        def customer_display_name(payload)
          customer_name(payload) || customer_email(payload) || customer_id(payload)
        end

        def customer_email(payload)
          payload["customer_email"].presence || expanded_customer(payload)["email"].presence
        end

        def expanded_customer(payload)
          payload["customer"].is_a?(Hash) ? payload["customer"] : {}
        end
    end
  end
end

module InvoiceSources
  class Xero
    class InvoiceSync
      def initialize(source, client: OauthClient.new)
        @source = source
        @client = client
      end

      def sync!
        payload = client.invoices(
          access_token: source.access_token,
          tenant_id: source.external_account_id
        )

        Array(payload.fetch("Invoices", [])).each do |invoice_payload|
          sync_invoice!(invoice_payload)
        end

        source.update!(status: :active, last_synced_at: Time.current, last_error: nil)
      rescue OauthClient::Error => error
        source.update!(status: :error, last_error: error.message)
        raise
      end

      def sync_invoice_by_id!(external_id)
        payload = client.invoice(
          access_token: source.access_token,
          tenant_id: source.external_account_id,
          invoice_id: external_id
        )

        sync_invoice!(Array(payload.fetch("Invoices", [])).first || {})
        source.update!(status: :active, last_synced_at: Time.current, last_error: nil)
      rescue KeyError, OauthClient::Error => error
        source.update!(status: :error, last_error: error.message)
        raise
      end

      private
        attr_reader :source, :client

        def sync_invoice!(payload)
          invoice = source.invoices.find_or_initialize_by(
            account: source.account,
            external_id: payload.fetch("InvoiceID")
          )

          contact = payload["Contact"] || {}
          invoice.update!(
            number: payload["InvoiceNumber"],
            invoice_type: payload["Type"],
            status: payload["Status"],
            currency: payload["CurrencyCode"],
            amount_due: payload["AmountDue"],
            amount_paid: payload["AmountPaid"],
            total: payload["Total"],
            issued_on: parse_date(payload["DateString"] || payload["Date"]),
            due_on: parse_date(payload["DueDateString"] || payload["DueDate"]),
            contact_external_id: contact["ContactID"],
            contact_name: contact["Name"],
            provider_data: {
              updated_date_utc: payload["UpdatedDateUTC"],
              reference: payload["Reference"],
              amount_credited: payload["AmountCredited"]
            },
            raw_data: payload,
            synced_at: Time.current
          )
        end

        def parse_date(value)
          Date.parse(value.to_s) if value.present?
        rescue Date::Error
          nil
        end
    end
  end
end

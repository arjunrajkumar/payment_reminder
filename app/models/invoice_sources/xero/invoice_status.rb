module InvoiceSources
  class Xero
    class InvoiceStatus
      STATUSES = {
        "DRAFT" => "pending",
        "SUBMITTED" => "pending",
        "AUTHORISED" => "open",
        "PAID" => "paid",
        "DELETED" => "void",
        "VOIDED" => "void"
      }.freeze

      def self.normalize(provider_status)
        STATUSES.fetch(provider_status.to_s.upcase, "unknown")
      end
    end
  end
end

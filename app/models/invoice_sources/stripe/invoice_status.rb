module InvoiceSources
  class Stripe
    class InvoiceStatus
      STATUSES = {
        "draft" => "pending",
        "open" => "open",
        "paid" => "paid",
        "uncollectible" => "uncollectible",
        "void" => "void"
      }.freeze

      def self.normalize(provider_status)
        STATUSES.fetch(provider_status.to_s.downcase, "unknown")
      end
    end
  end
end

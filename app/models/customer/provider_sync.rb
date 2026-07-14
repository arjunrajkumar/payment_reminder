module Customer::ProviderSync
  extend ActiveSupport::Concern

  class_methods do
    def sync_from_provider!(invoice_source:, external_id:, name:, email:, observed_at: nil)
      invoice_source.customers.find_or_initialize_by(external_id: external_id).tap do |customer|
        customer.account = invoice_source.account
        refresh_provider_details(customer, name: name, email: email, observed_at: observed_at)
        customer.save!
      end
    end

    private
      def refresh_provider_details(customer, name:, email:, observed_at:)
        details_are_current = observed_at.present? && (
          customer.details_observed_at.blank? || observed_at >= customer.details_observed_at
        )
        return unless customer.new_record? || details_are_current

        customer.name = name.presence || customer.name.presence || email.presence || customer.external_id || "Unknown customer"
        customer.email = email if email.present?
        customer.details_observed_at = observed_at if observed_at.present?
      end
  end
end

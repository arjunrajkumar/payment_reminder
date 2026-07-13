class Customers::Collection
  def initialize(invoices, as_of: Date.current)
    @invoices = Receivables::Dashboard.new(invoices, as_of: as_of).issued_invoices
    @as_of = as_of
  end

  def profiles
    @profiles ||= build_profiles
  end

  def find!(key)
    profiles.find { |profile| profile.to_param == key.to_s } || raise(ActiveRecord::RecordNotFound)
  end

  private
    attr_reader :as_of, :invoices

    def build_profiles
      invoices
        .group_by { |invoice| Customers::Profile.identity_for(invoice) }
        .map { |identity, customer_invoices| Customers::Profile.new(customer_invoices, identity: identity, as_of: as_of) }
        .sort_by { |profile| profile.name.downcase }
    end
end

require "test_helper"

class Customers::CollectionTest < ActiveSupport::TestCase
  test "groups invoices by customer identity and sorts profiles by name" do
    beta_first = invoice(contact_external_id: "beta", contact_name: "Beta Customer")
    beta_second = invoice(contact_external_id: "beta", contact_name: "Beta Customer")
    alpha = invoice(contact_external_id: nil, contact_name: "Alpha Customer", issued_on: Date.new(2026, 7, 2))
    alpha_again = invoice(contact_external_id: nil, contact_name: "  alpha   customer ")

    profiles = Customers::Collection.new([ beta_first, alpha, beta_second, alpha_again ]).profiles

    assert_equal [ "Alpha Customer", "Beta Customer" ], profiles.map(&:name)
    assert_equal [ 2, 2 ], profiles.map { |profile| profile.invoices.size }
  end

  test "finds a customer by its encoded route key" do
    collection = Customers::Collection.new([ invoice(contact_external_id: "customer-123") ])
    customer = collection.profiles.first

    assert_equal customer, collection.find!(customer.to_param)
    assert_raises(ActiveRecord::RecordNotFound) { collection.find!("missing") }
  end

  private
    def invoice(contact_external_id:, contact_name: "Example Customer", issued_on: Date.new(2026, 7, 1))
      Invoice.new(
        invoice_source: invoice_sources(:xero),
        invoice_type: "ACCREC",
        external_id: SecureRandom.uuid,
        contact_external_id: contact_external_id,
        contact_name: contact_name,
        currency: "INR",
        issued_on: issued_on,
        due_on: Date.new(2026, 7, 31),
        status: "AUTHORISED",
        total: 100,
        amount_due: 100,
        amount_paid: 0
      )
    end
end

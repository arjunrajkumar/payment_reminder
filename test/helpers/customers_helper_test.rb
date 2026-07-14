require "test_helper"

class CustomersHelperTest < ActionView::TestCase
  include CustomersHelper

  test "derives display status from persisted invoice state in precedence order" do
    assert_equal status(:overdue), customer_invoice_status(customer(overdue: 1, outstanding: 1, uncollectible: 1, open: 1))
    assert_equal status(:outstanding), customer_invoice_status(customer(outstanding: 1, uncollectible: 1, open: 1))
    assert_equal status(:uncollectible), customer_invoice_status(customer(uncollectible: 1, open: 1))
    assert_equal status(:open), customer_invoice_status(customer(open: 1))
    assert_equal status(:paid), customer_invoice_status(customer)
  end

  private
    def customer(overdue: 0, outstanding: 0, uncollectible: 0, open: 0)
      Struct.new(:overdue_invoices, :outstanding_invoices, :uncollectible_invoices, :open_invoices, keyword_init: true).new(
        overdue_invoices: Array.new(overdue) { Object.new },
        outstanding_invoices: Array.new(outstanding) { Object.new },
        uncollectible_invoices: Array.new(uncollectible) { Object.new },
        open_invoices: Array.new(open) { Object.new }
      )
    end

    def status(key)
      CustomersHelper::CUSTOMER_INVOICE_STATUSES.fetch(key)
    end
end

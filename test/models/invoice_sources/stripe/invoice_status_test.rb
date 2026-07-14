require "test_helper"

module InvoiceSources
  class Stripe::InvoiceStatusTest < ActiveSupport::TestCase
    test "normalizes Stripe invoice statuses" do
      assert_equal "pending", Stripe::InvoiceStatus.normalize("draft")
      assert_equal "open", Stripe::InvoiceStatus.normalize("open")
      assert_equal "paid", Stripe::InvoiceStatus.normalize("paid")
      assert_equal "uncollectible", Stripe::InvoiceStatus.normalize("uncollectible")
      assert_equal "void", Stripe::InvoiceStatus.normalize("void")
    end

    test "normalizes an unsupported status as unknown" do
      assert_equal "unknown", Stripe::InvoiceStatus.normalize("new_status")
      assert_equal "unknown", Stripe::InvoiceStatus.normalize(nil)
    end
  end
end

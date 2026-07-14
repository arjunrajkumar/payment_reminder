require "test_helper"

module InvoiceSources
  class Xero::InvoiceStatusTest < ActiveSupport::TestCase
    test "normalizes Xero invoice statuses" do
      assert_equal "pending", Xero::InvoiceStatus.normalize("DRAFT")
      assert_equal "pending", Xero::InvoiceStatus.normalize("SUBMITTED")
      assert_equal "open", Xero::InvoiceStatus.normalize("AUTHORISED")
      assert_equal "paid", Xero::InvoiceStatus.normalize("PAID")
      assert_equal "void", Xero::InvoiceStatus.normalize("DELETED")
      assert_equal "void", Xero::InvoiceStatus.normalize("VOIDED")
    end

    test "normalizes an unsupported status as unknown" do
      assert_equal "unknown", Xero::InvoiceStatus.normalize("NEW_STATUS")
      assert_equal "unknown", Xero::InvoiceStatus.normalize(nil)
    end
  end
end

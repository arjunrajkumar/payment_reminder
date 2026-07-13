require "test_helper"

class Customers::PayerProfileTest < ActiveSupport::TestCase
  test "classifies customers with limited payment history as new" do
    assert_equal "New", category_for(history: 2, on_time_rate: 100, days_from_due: 0).fetch(:name)
  end

  test "classifies customers that reliably pay by the due date" do
    assert_equal "Pays on time", category_for(history: 3, on_time_rate: 80, days_from_due: 0).fetch(:name)
  end

  test "classifies customers with mixed timing as sometimes late" do
    assert_equal "Sometimes late", category_for(history: 3, on_time_rate: 70, days_from_due: 7).fetch(:name)
  end

  test "classifies customers whose typical payment is late as slow payers" do
    assert_equal "Slow payer", category_for(history: 3, on_time_rate: 40, days_from_due: 8).fetch(:name)
  end

  test "classifies a long and inconsistent late history as unreliable" do
    category = category_for(
      history: 5,
      on_time_rate: 40,
      days_from_due: 8,
      confidence: "Low"
    )

    assert_equal "Unreliable payer", category.fetch(:name)
  end

  test "supports a deliberate category override for prototype customer data" do
    customer = customer_with(history: 0, on_time_rate: nil, days_from_due: nil)

    category = Customers::PayerProfile.new(customer, override: { key: :slow_payer }).to_h

    assert_equal Customers::PayerProfile::CATEGORIES.fetch(:slow_payer), category
  end

  private
    def category_for(history:, on_time_rate:, days_from_due:, confidence: "Medium")
      Customers::PayerProfile.new(
        customer_with(
          history: history,
          on_time_rate: on_time_rate,
          days_from_due: days_from_due,
          confidence: confidence
        )
      ).to_h
    end

    def customer_with(history:, on_time_rate:, days_from_due:, confidence: "Medium")
      Struct.new(
        :payment_history_count,
        :on_time_rate,
        :forecast_days_from_due,
        :forecast_confidence,
        keyword_init: true
      ).new(
        payment_history_count: history,
        on_time_rate: on_time_rate,
        forecast_days_from_due: days_from_due,
        forecast_confidence: confidence
      )
    end
end

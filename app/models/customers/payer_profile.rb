class Customers::PayerProfile
  MINIMUM_PAYMENT_HISTORY = 3
  MINIMUM_UNRELIABLE_HISTORY = 5
  PAYS_ON_TIME_RATE = 80
  UNRELIABLE_ON_TIME_RATE = 50
  SLOW_PAYER_DAYS = 7

  # A payer profile describes durable payment behavior from persisted invoice
  # due dates and payment dates.
  CATEGORIES = {
    new: {
      name: "New",
      rule: "Fewer than #{MINIMUM_PAYMENT_HISTORY} paid invoices with usable due and payment dates"
    },
    pays_on_time: {
      name: "Pays on time",
      rule: "At least #{MINIMUM_PAYMENT_HISTORY} recorded payments with #{PAYS_ON_TIME_RATE}% or more paid on time"
    },
    sometimes_late: {
      name: "Sometimes late",
      rule: "Enough payment history to judge, but neither consistently on time nor typically more than #{SLOW_PAYER_DAYS} days late"
    },
    slow_payer: {
      name: "Slow payer",
      rule: "The typical recorded payment arrives more than #{SLOW_PAYER_DAYS} days after its due date"
    },
    unreliable_payer: {
      name: "Unreliable payer",
      rule: "At least #{MINIMUM_UNRELIABLE_HISTORY} recorded payments, fewer than #{UNRELIABLE_ON_TIME_RATE}% paid on time, typically more than #{SLOW_PAYER_DAYS} days late, with inconsistent timing"
    }
  }.freeze

  def initialize(customer)
    @customer = customer
  end

  def to_h
    category
  end

  private
    attr_reader :customer

    def key
      @key ||= inferred_key
    end

    def category
      CATEGORIES.fetch(key)
    end

    def inferred_key
      return :new if customer.payment_history_count < MINIMUM_PAYMENT_HISTORY
      return :unreliable_payer if unreliable_payment_pattern?
      return :pays_on_time if customer.on_time_rate.to_i >= PAYS_ON_TIME_RATE
      return :slow_payer if customer.forecast_days_from_due.to_i > SLOW_PAYER_DAYS

      :sometimes_late
    end

    def unreliable_payment_pattern?
      customer.payment_history_count >= MINIMUM_UNRELIABLE_HISTORY &&
        customer.on_time_rate < UNRELIABLE_ON_TIME_RATE &&
        customer.forecast_days_from_due.to_i > SLOW_PAYER_DAYS &&
        customer.forecast_confidence == "Low"
    end
end

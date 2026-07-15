module Customer::PayerSegment
  extend ActiveSupport::Concern

  PAYER_SEGMENTS = %w[ new pays_on_time sometimes_late slow_payer unreliable_payer ].index_by(&:itself).freeze
  PAYMENT_HISTORY_LIMIT = 12

  included do
    enum :payer_segment, PAYER_SEGMENTS, prefix: true, validate: true
  end

  def refresh_payer_segment!
    with_lock do
      update!(payer_segment: payer_segment_from(recent_payment_outcomes))
    end

    self
  end

  private
    def recent_payment_outcomes
      eligible_payments = invoices
        .where(status: :paid)
        .where.not(due_on: nil)
        .where.not(paid_on: nil)
      uncollectible_invoices = invoices.where(status: :uncollectible)

      eligible_payments
        .or(uncollectible_invoices)
        .order(issued_on: :desc, due_on: :desc, created_at: :desc, id: :desc)
        .limit(PAYMENT_HISTORY_LIMIT)
        .to_a
    end

    def payer_segment_from(outcomes)
      return :unreliable_payer if outcomes.any?(&:status_uncollectible?)

      payments = outcomes.select(&:status_paid?)
      return :new if payments.size < account.payer_segment_minimum_payment_history

      delays = payment_delays(payments)
      return :unreliable_payer if unreliable_payment_pattern?(payments, delays)
      return :pays_on_time if on_time_rate(payments) >= account.payer_segment_pays_on_time_rate
      return :slow_payer if typical_payment_delay(delays).to_i > account.payer_segment_slow_payer_days

      :sometimes_late
    end

    def unreliable_payment_pattern?(payments, delays)
      payments.size >= account.payer_segment_minimum_unreliable_history &&
        on_time_rate(payments) < account.payer_segment_unreliable_on_time_rate &&
        typical_payment_delay(delays).to_i > account.payer_segment_slow_payer_days &&
        inconsistent_payment_timing?(delays)
    end

    def on_time_rate(payments)
      on_time_count = payments.count { |invoice| invoice.paid_on <= invoice.due_on }
      ((on_time_count.to_f / payments.size) * 100).round
    end

    def payment_delays(payments)
      payments.map { |invoice| (invoice.paid_on - invoice.due_on).to_i }
    end

    def typical_payment_delay(delays)
      median(forecast_payment_delays(delays))
    end

    def inconsistent_payment_timing?(delays)
      forecast_delays = forecast_payment_delays(delays)
      forecast_delays.size < 3 || forecast_delays.max - forecast_delays.min > 14
    end

    def forecast_payment_delays(delays)
      return delays if delays.size < account.payer_segment_minimum_payment_history

      typical_delay = median(delays)
      deviations = delays.map { |delay| (delay - typical_delay).abs }
      threshold = [ median(deviations) * 3, 30 ].max

      delays.reject { |delay| (delay - typical_delay).abs > threshold }
    end

    def median(values)
      return if values.empty?

      sorted_values = values.sort
      midpoint = sorted_values.length / 2
      return sorted_values.fetch(midpoint) if sorted_values.length.odd?

      ((sorted_values.fetch(midpoint - 1) + sorted_values.fetch(midpoint)) / 2.0).round
    end
end

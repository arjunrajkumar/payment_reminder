module Customer::PaymentHistory
  extend ActiveSupport::Concern

  def payment_history_count
    paid_invoices_with_dates.size
  end

  def on_time_rate
    return if payment_history_count.zero?

    on_time_count = paid_invoices_with_dates.count { |invoice| invoice.paid_on <= invoice.due_on }
    ((on_time_count.to_f / payment_history_count) * 100).round
  end

  def forecast_days_from_due
    median(forecast_payment_delays)
  end

  def forecast_confidence
    return "Due date only" if forecast_payment_delays.empty?

    spread = forecast_payment_delays.max - forecast_payment_delays.min
    return "High" if forecast_payment_delays.size >= 5 && spread <= 7
    return "Medium" if forecast_payment_delays.size >= 3 && spread <= 14

    "Low"
  end

  def invoice_timing_events
    issued_invoices
      .select(&:due_on)
      .sort_by(&:due_on)
      .reverse
      .map { |invoice| invoice_timing_event(invoice) }
  end

  def last_payment_on
    paid_invoices.filter_map(&:paid_on).max
  end

  private
    def invoice_timing_event(invoice)
      paid = invoice.paid?
      uncollectible = invoice.uncollectible?
      no_balance_due = invoice.open? && !invoice.outstanding?
      timing_date = if uncollectible || no_balance_due
        nil
      elsif paid
        invoice.paid_on
      else
        as_of
      end
      delay = (timing_date - invoice.due_on).to_i if timing_date
      position = 50 + ((delay.clamp(-30, 30) / 60.0) * 100) if delay

      {
        invoice: invoice,
        delay: delay,
        paid: paid,
        uncollectible: uncollectible,
        no_balance_due: no_balance_due,
        position: position
      }
    end

    def paid_invoices_with_dates
      @paid_invoices_with_dates ||= paid_invoices.select { |invoice| invoice.paid_on && invoice.due_on }
    end

    def forecast_payment_delays
      @forecast_payment_delays ||= paid_invoices_with_dates
        .reject { |invoice| unusual_payment_dates.include?(invoice) }
        .map { |invoice| payment_delay_for(invoice) }
    end

    def unusual_payment_dates
      @unusual_payment_dates ||= if payment_history_count < 3
        []
      else
        typical_delay = median(payment_delay_days)
        deviations = payment_delay_days.map { |delay| (delay - typical_delay).abs }
        threshold = [ median(deviations) * 3, 30 ].max

        paid_invoices_with_dates.select do |invoice|
          (payment_delay_for(invoice) - typical_delay).abs > threshold
        end
      end
    end

    def payment_delay_days
      @payment_delay_days ||= paid_invoices_with_dates.map { |invoice| payment_delay_for(invoice) }
    end

    def payment_delay_for(invoice)
      (invoice.paid_on - invoice.due_on).to_i
    end

    def median(values)
      return if values.empty?

      sorted_values = values.sort
      midpoint = sorted_values.length / 2
      return sorted_values.fetch(midpoint) if sorted_values.length.odd?

      ((sorted_values.fetch(midpoint - 1) + sorted_values.fetch(midpoint)) / 2.0).round
    end
end

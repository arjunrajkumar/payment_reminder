require "base64"

class Customers::Profile
  attr_reader :as_of, :identity, :invoices

  class << self
    def identity_for(invoice)
      customer_identity = if invoice.contact_external_id.present?
        [ "contact", invoice.contact_external_id ]
      else
        [ "name", invoice.contact_name.to_s.squish.downcase ]
      end

      [ invoice.invoice_source_id, *customer_identity ]
    end

    def encode_identity(identity)
      Base64.urlsafe_encode64(identity.to_json, padding: false)
    end
  end

  def initialize(invoices, identity:, as_of: Date.current)
    @invoices = invoices.sort_by { |invoice| invoice.issued_on || Date.new(1, 1, 1) }.reverse
    @identity = identity
    @as_of = as_of
    @dashboard = Receivables::Dashboard.new(@invoices, as_of: as_of)
  end

  def to_param
    self.class.encode_identity(identity)
  end

  def name
    invoices.filter_map { |invoice| invoice.contact_name.presence }.first || "Unknown customer"
  end

  def email
    invoices.filter_map do |invoice|
      invoice.provider_data["customer_email"].presence ||
        invoice.raw_data.dig("Contact", "EmailAddress").presence
    end.first
  end

  def outstanding_invoices
    @dashboard.outstanding_invoices
  end

  def overdue_invoices
    @dashboard.overdue_invoices
  end

  def paid_invoices
    @dashboard.paid_invoices
  end

  def outstanding_totals
    @dashboard.outstanding_totals
  end

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

  def next_expected_invoice
    outstanding_invoices.min_by { |invoice| invoice.due_on || Date.new(9999, 12, 31) }
  end

  def invoice_timing_events
    invoices
      .select(&:due_on)
      .sort_by(&:due_on)
      .reverse
      .map do |invoice|
        paid = invoice.paid?
        timing_date = paid ? invoice.paid_on : as_of
        delay = (timing_date - invoice.due_on).to_i if timing_date
        position = 50 + ((delay.clamp(-30, 30) / 60.0) * 100) if delay

        {
          invoice: invoice,
          delay: delay,
          paid: paid,
          position: position
        }
      end
  end

  def last_payment_on
    paid_invoices.filter_map(&:paid_on).max
  end

  def oldest_overdue_days
    overdue_invoices.filter_map do |invoice|
      (as_of - invoice.due_on).to_i if invoice.due_on
    end.max
  end

  private
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

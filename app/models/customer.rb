class Customer < ApplicationRecord
  belongs_to :account, inverse_of: :customers
  belongs_to :invoice_source, inverse_of: :customers
  has_many :invoices, dependent: :destroy, inverse_of: :customer
  has_many :issued_invoices, -> { issued.recent }, class_name: "Invoice"

  validates :external_id, :name, presence: true
  validates :external_id, uniqueness: { scope: :invoice_source_id }

  scope :with_issued_invoices, -> { joins(:invoices).merge(Invoice.issued).distinct }

  class << self
    def sync_from_provider!(invoice_source:, external_id:, name:, email:, observed_at: nil)
      invoice_source.customers.find_or_initialize_by(external_id: external_id).tap do |customer|
        customer.account = invoice_source.account
        refresh_provider_details(customer, name: name, email: email, observed_at: observed_at)
        customer.save!
      end
    end

    private
      def refresh_provider_details(customer, name:, email:, observed_at:)
        details_are_current = observed_at.present? && (
          customer.details_observed_at.blank? || observed_at >= customer.details_observed_at
        )
        return unless customer.new_record? || details_are_current

        customer.name = name.presence || customer.name.presence || email.presence || customer.external_id || "Unknown customer"
        customer.email = email if email.present?
        customer.details_observed_at = observed_at if observed_at.present?
      end
  end

  def as_of
    @as_of ||= Date.current
  end

  def outstanding_invoices
    receivables.outstanding_invoices
  end

  def open_invoices
    receivables.open_invoices
  end

  def overdue_invoices
    receivables.overdue_invoices
  end

  def paid_invoices
    receivables.paid_invoices
  end

  def uncollectible_invoices
    receivables.uncollectible_invoices
  end

  def outstanding_totals
    receivables.outstanding_totals
  end

  def uncollectible_totals
    receivables.uncollectible_totals
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
    issued_invoices
      .select(&:due_on)
      .sort_by(&:due_on)
      .reverse
      .map { |invoice| invoice_timing_event(invoice) }
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
    def receivables
      @receivables ||= Receivables::Dashboard.new(issued_invoices.to_a, as_of: as_of)
    end

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

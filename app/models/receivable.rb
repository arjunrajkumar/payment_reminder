class Receivable < ApplicationRecord
  STATUSES = %w[ none outstanding uncollectible open paid ].index_by(&:itself).freeze
  PAYER_SEGMENTS = %w[ new pays_on_time sometimes_late slow_payer unreliable_payer ].index_by(&:itself).freeze

  PAYMENT_HISTORY_LIMIT = 12

  belongs_to :account, inverse_of: :receivables
  belongs_to :customer, inverse_of: :receivable

  attribute :outstanding_totals, default: -> { {} }
  attribute :uncollectible_totals, default: -> { {} }

  enum :status, STATUSES, prefix: true, validate: true
  enum :payer_segment, PAYER_SEGMENTS, prefix: true, validate: true

  validates :customer_id, uniqueness: true
  validate :account_matches_customer

  scope :active, -> { where.not(status: :none) }
  scope :for_inbox, ->(as_of: Date.current) do
    status_order = Arel::Nodes::Case.new
      .when(arel_table[:status].eq("outstanding").and(arel_table[:due_on].lt(as_of))).then(0)
      .when(arel_table[:status].eq("outstanding")).then(1)
      .when(arel_table[:status].eq("paid")).then(2)
      .else(3)

    active
      .eager_load(:customer)
      .order(status_order.asc, Customer.arel_table[:name].asc, arel_table[:id].asc)
  end

  class << self
    def refresh_for!(customer)
      customer.with_lock do
        invoices = customer.invoices.issued.recent.to_a
        receivable = customer.receivable || customer.build_receivable

        receivable.update!(
          account: customer.account,
          **summary_attributes(invoices),
          payer_segment: payer_segment_for(invoices, account: customer.account),
          calculated_at: Time.current
        )
        receivable
      end
    end

    def refresh_for_account!(account)
      account.customers.find_each { |customer| refresh_for!(customer) }
    end

    private
      def summary_attributes(invoices)
        open_invoices = invoices.select(&:open?)
        outstanding_invoices = open_invoices.select(&:outstanding?)
        uncollectible_invoices = invoices.select(&:uncollectible?)

        {
          status: status_for(invoices, open_invoices, outstanding_invoices, uncollectible_invoices),
          due_on: outstanding_invoices.filter_map(&:due_on).min,
          outstanding_totals: amount_due_totals(outstanding_invoices),
          uncollectible_totals: amount_due_totals(uncollectible_invoices),
          open_invoice_count: open_invoices.size,
          outstanding_invoice_count: outstanding_invoices.size,
          uncollectible_invoice_count: uncollectible_invoices.size
        }
      end

      def status_for(invoices, open_invoices, outstanding_invoices, uncollectible_invoices)
        return :outstanding if outstanding_invoices.any?
        return :uncollectible if uncollectible_invoices.any?
        return :open if open_invoices.any?
        return :paid if invoices.any?

        :none
      end

      def amount_due_totals(invoices)
        totals = invoices.each_with_object(Hash.new(0.to_d)) do |invoice, result|
          result[invoice.currency.presence || "Unspecified"] += invoice.amount_due.to_d
        end

        totals.transform_values { |amount| format("%.2f", amount) }
      end

      def payer_segment_for(invoices, account:)
        outcomes = invoices
          .select { |invoice| invoice.uncollectible? || eligible_payment?(invoice) }
          .first(PAYMENT_HISTORY_LIMIT)

        return :unreliable_payer if outcomes.any?(&:uncollectible?)

        payments = outcomes.select(&:paid?)
        return :new if payments.size < account.payer_segment_minimum_payment_history

        delays = payment_delays(payments)
        return :unreliable_payer if unreliable_payment_pattern?(payments, delays, account:)
        return :pays_on_time if on_time_rate(payments) >= account.payer_segment_pays_on_time_rate
        return :slow_payer if typical_payment_delay(delays, account:).to_i > account.payer_segment_slow_payer_days

        :sometimes_late
      end

      def eligible_payment?(invoice)
        invoice.paid? && invoice.due_on.present? && invoice.paid_on.present?
      end

      def unreliable_payment_pattern?(payments, delays, account:)
        payments.size >= account.payer_segment_minimum_unreliable_history &&
          on_time_rate(payments) < account.payer_segment_unreliable_on_time_rate &&
          typical_payment_delay(delays, account:).to_i > account.payer_segment_slow_payer_days &&
          inconsistent_payment_timing?(delays, account:)
      end

      def on_time_rate(payments)
        on_time_count = payments.count { |invoice| invoice.paid_on <= invoice.due_on }
        ((on_time_count.to_f / payments.size) * 100).round
      end

      def payment_delays(payments)
        payments.map { |invoice| (invoice.paid_on - invoice.due_on).to_i }
      end

      def typical_payment_delay(delays, account:)
        median(forecast_payment_delays(delays, account:))
      end

      def inconsistent_payment_timing?(delays, account:)
        forecast_delays = forecast_payment_delays(delays, account:)
        forecast_delays.size < 3 || forecast_delays.max - forecast_delays.min > 14
      end

      def forecast_payment_delays(delays, account:)
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

  def overdue?(as_of: Date.current)
    status_outstanding? && due_on.present? && due_on < as_of
  end

  def display_status(as_of: Date.current)
    overdue?(as_of:) ? :overdue : status.to_sym
  end

  private
    def account_matches_customer
      return if account.blank? || customer.blank? || account_id == customer.account_id

      errors.add(:account, "must match customer account")
    end
end

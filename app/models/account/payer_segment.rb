module Account::PayerSegment
  extend ActiveSupport::Concern

  HISTORY_OPTIONS = (1..12).to_a.freeze
  PAYS_ON_TIME_RATE_OPTIONS = (50..100).step(5).to_a.freeze
  UNRELIABLE_ON_TIME_RATE_OPTIONS = (0..75).step(5).to_a.freeze
  SLOW_PAYER_DAYS_OPTIONS = [ 1, 3, 5, 7, 10, 14, 21, 30, 45, 60, 90 ].freeze
  RULE_ATTRIBUTES = %i[
    payer_segment_minimum_payment_history
    payer_segment_minimum_unreliable_history
    payer_segment_pays_on_time_rate
    payer_segment_unreliable_on_time_rate
    payer_segment_slow_payer_days
  ].freeze

  included do
    validates :payer_segment_minimum_payment_history,
      :payer_segment_minimum_unreliable_history,
      inclusion: { in: HISTORY_OPTIONS }
    validates :payer_segment_pays_on_time_rate,
      inclusion: { in: PAYS_ON_TIME_RATE_OPTIONS }
    validates :payer_segment_unreliable_on_time_rate,
      inclusion: { in: UNRELIABLE_ON_TIME_RATE_OPTIONS }
    validates :payer_segment_slow_payer_days,
      inclusion: { in: SLOW_PAYER_DAYS_OPTIONS }
    validate :unreliable_history_covers_minimum_history
    validate :unreliable_rate_is_below_pays_on_time_rate
  end

  def refresh_payer_segments!
    customers.find_each(&:refresh_payer_segment!)
    self
  end

  private
    def unreliable_history_covers_minimum_history
      return if payer_segment_minimum_payment_history.nil? || payer_segment_minimum_unreliable_history.nil?
      return if payer_segment_minimum_unreliable_history >= payer_segment_minimum_payment_history

      errors.add(:payer_segment_minimum_unreliable_history, "must be at least the minimum payment history")
    end

    def unreliable_rate_is_below_pays_on_time_rate
      return if payer_segment_pays_on_time_rate.nil? || payer_segment_unreliable_on_time_rate.nil?
      return if payer_segment_unreliable_on_time_rate < payer_segment_pays_on_time_rate

      errors.add(:payer_segment_unreliable_on_time_rate, "must be lower than the pays-on-time rate")
    end
end

module Account::CustomerSegments
  extend ActiveSupport::Concern

  included do
    accepts_nested_attributes_for :customer_segments
    before_validation :build_default_customer_segments, on: :create
    validate :has_all_customer_segments
    validate :customer_segment_rules_do_not_overlap
  end

  def customer_segment(payer_segment)
    customer_segments.find_by!(payer_segment: payer_segment)
  end

  def refresh_customer_segments!
    customers.find_each(&:refresh_customer_segment!)
    self
  end

  private
    def build_default_customer_segments
      existing_segments = customer_segments.map(&:payer_segment)

      CustomerSegment::DEFAULTS.each do |payer_segment, attributes|
        next if payer_segment.to_s.in?(existing_segments)

        customer_segments.build(payer_segment: payer_segment, **attributes)
      end
    end

    def has_all_customer_segments
      segment_names = customer_segments.reject(&:marked_for_destruction?).filter_map(&:payer_segment)
      return if segment_names.sort == CustomerSegment::PAYER_SEGMENTS.keys.sort

      errors.add(:customer_segments, "must contain each payer segment exactly once")
    end

    def customer_segment_rules_do_not_overlap
      segments = customer_segments.to_a.index_by(&:payer_segment)
      good_segment = segments["good_debtor"]
      bad_segment = segments["bad_debtor"]
      return unless good_segment && bad_segment

      if good_segment.on_time_rate.to_i <= bad_segment.on_time_rate.to_i
        errors.add(:base, "Good Debtor on-time rate must stay above the Bad Debtor on-time rate")
      end
    end
end

class CustomerSegment < ApplicationRecord
  PAYER_SEGMENTS = %w[ good_debtor normal_debtor bad_debtor ].index_by(&:itself).freeze
  PAYMENT_HISTORY_LIMIT = 12
  MINIMUM_COMPLETED_OUTCOMES = 3
  ON_TIME_RATE_OPTIONS = (0..100).step(5).to_a.freeze
  DEFAULTS = {
    good_debtor: { on_time_rate: 80 },
    normal_debtor: {},
    bad_debtor: { on_time_rate: 50 }
  }.freeze

  belongs_to :account, inverse_of: :customer_segments
  has_many :customers, dependent: :restrict_with_exception, inverse_of: :customer_segment

  enum :payer_segment, PAYER_SEGMENTS, prefix: true, validate: true

  validates :payer_segment, uniqueness: { scope: :account_id }
  validates :on_time_rate, inclusion: { in: ON_TIME_RATE_OPTIONS }, if: :configures_on_time_rate?
  validates :on_time_rate, absence: true, if: :payer_segment_normal_debtor?
  validate :rules_do_not_overlap

  before_destroy :prevent_removing_account_segment

  attr_readonly :account_id, :payer_segment

  private
    def configures_on_time_rate?
      payer_segment_good_debtor? || payer_segment_bad_debtor?
    end

    def rules_do_not_overlap
      good_segment = account_segment("good_debtor")
      bad_segment = account_segment("bad_debtor")
      return unless good_segment && bad_segment

      validate_on_time_rate_order(good_segment, bad_segment)
    end

    def validate_on_time_rate_order(good_segment, bad_segment)
      return if good_segment.on_time_rate.blank? || bad_segment.on_time_rate.blank?
      return if good_segment.on_time_rate > bad_segment.on_time_rate

      if payer_segment_good_debtor?
        errors.add(:on_time_rate, "must stay above the Bad Debtor on-time rate")
      elsif payer_segment_bad_debtor?
        errors.add(:on_time_rate, "must stay below the Good Debtor on-time rate")
      end
    end

    def account_segment(segment_name)
      return self if payer_segment == segment_name
      return unless account

      segments = account.customer_segments
      if segments.loaded?
        segments.target.find { |segment| segment.payer_segment == segment_name }
      else
        segments.find_by(payer_segment: segment_name)
      end
    end

    def prevent_removing_account_segment
      return if destroyed_by_association&.name == :customer_segments

      errors.add(:base, "Account customer segments cannot be removed")
      throw :abort
    end
end

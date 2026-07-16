module Customer::Segmentation
  extend ActiveSupport::Concern

  def refresh_customer_segment!
    with_lock do
      segment_rules = account.customer_segments.index_by(&:payer_segment)
      selected_payer_segment = segment_for(recent_completed_outcomes, segment_rules:)
      self.customer_segment = segment_rules.fetch(selected_payer_segment)
      save!
    end

    self
  end

  private
    def recent_completed_outcomes
      paid_invoices = invoices
        .where(status: :paid)
        .where.not(due_on: nil)
        .where.not(paid_on: nil)
      uncollectible_invoices = invoices
        .where(status: :uncollectible)

      paid_invoices
        .or(uncollectible_invoices)
        .order(completed_on: :desc, issued_on: :desc, created_at: :desc, id: :desc)
        .limit(CustomerSegment::PAYMENT_HISTORY_LIMIT)
        .to_a
    end

    def segment_for(outcomes, segment_rules:)
      return "normal_debtor" if outcomes.size < CustomerSegment::MINIMUM_COMPLETED_OUTCOMES

      rate = on_time_rate(outcomes)
      return "good_debtor" if rate >= segment_rules.fetch("good_debtor").on_time_rate
      return "bad_debtor" if rate < segment_rules.fetch("bad_debtor").on_time_rate

      "normal_debtor"
    end

    def on_time_rate(outcomes)
      on_time_count = outcomes.count do |invoice|
        invoice.status_paid? && invoice.paid_on <= invoice.due_on
      end
      ((on_time_count.to_f / outcomes.size) * 100).round
    end
end

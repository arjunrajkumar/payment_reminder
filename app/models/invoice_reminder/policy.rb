class InvoiceReminder::Policy
  Stage = Data.define(:category, :day_offset, :tone) do
    def key
      "#{category}_#{day_offset}"
    end

    def date_for(due_on:)
      case category
      when :pre_due
        due_on - day_offset.days
      when :overdue
        due_on + day_offset.days
      end
    end

    def invoice_due_on_for(reminder_on:)
      case category
      when :pre_due
        reminder_on + day_offset.days
      when :overdue
        reminder_on - day_offset.days
      end
    end
  end

  SCHEDULES = {
    good_debtor: [
      Stage.new(category: :pre_due, day_offset: 3, tone: :friendly),
      Stage.new(category: :overdue, day_offset: 3, tone: :neutral),
      Stage.new(category: :overdue, day_offset: 10, tone: :final)
    ].freeze,
    normal_debtor: [
      Stage.new(category: :pre_due, day_offset: 7, tone: :friendly),
      Stage.new(category: :pre_due, day_offset: 1, tone: :direct),
      Stage.new(category: :overdue, day_offset: 3, tone: :direct),
      Stage.new(category: :overdue, day_offset: 7, tone: :firm),
      Stage.new(category: :overdue, day_offset: 14, tone: :final)
    ].freeze,
    bad_debtor: [
      Stage.new(category: :pre_due, day_offset: 14, tone: :direct),
      Stage.new(category: :pre_due, day_offset: 7, tone: :direct),
      Stage.new(category: :pre_due, day_offset: 3, tone: :direct),
      Stage.new(category: :pre_due, day_offset: 1, tone: :direct),
      Stage.new(category: :overdue, day_offset: 1, tone: :firm),
      Stage.new(category: :overdue, day_offset: 5, tone: :final)
    ].freeze
  }.freeze

  def self.stages_for(payer_segment:)
    SCHEDULES.fetch(payer_segment.to_s.to_sym)
  end

  def self.stage_for(payer_segment:, stage_key:)
    stages_for(payer_segment:).find { |stage| stage.key == stage_key }
  end
end

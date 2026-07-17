module Account::InvoiceSchedules
  extend ActiveSupport::Concern

  included do
    has_many :invoice_schedules, dependent: :destroy, inverse_of: :account
    before_validation :build_default_invoice_schedules, on: :create
  end

  private
    def build_default_invoice_schedules
      existing_schedule_keys = invoice_schedules.map do |schedule|
        [ schedule.kind, schedule.category, schedule.day_offset ]
      end

      InvoiceReminder::Policy::SCHEDULES.each do |kind, stages|
        stages.each do |stage|
          schedule_key = [ kind.to_s, stage.category.to_s, stage.day_offset ]
          next if schedule_key.in?(existing_schedule_keys)

          invoice_schedules.build(
            kind:,
            category: stage.category,
            day_offset: stage.day_offset,
            tone: stage.tone
          )
        end
      end
    end
end

class InvoiceSchedule < ApplicationRecord
  KINDS = CustomerSegment::PAYER_SEGMENTS
  CATEGORIES = InvoiceReminder::CATEGORIES
  TONES = InvoiceReminder::TONES

  belongs_to :account, inverse_of: :invoice_schedules
  has_many :invoice_reminders, dependent: :nullify, inverse_of: :invoice_schedule

  enum :kind, KINDS, prefix: true, validate: true
  enum :category, CATEGORIES, prefix: true, validate: true
  enum :tone, TONES, prefix: true, validate: true

  validates :day_offset, numericality: { only_integer: true, greater_than: 0 }
  validates :day_offset, uniqueness: { scope: %i[account_id kind category] }

  def key
    "#{category}_#{day_offset}"
  end

  def date_for(due_on:)
    category_pre_due? ? due_on - day_offset.days : due_on + day_offset.days
  end

  def invoice_due_on_for(reminder_on:)
    category_pre_due? ? reminder_on + day_offset.days : reminder_on - day_offset.days
  end
end

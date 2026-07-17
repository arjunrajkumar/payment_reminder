class InvoiceReminder < ApplicationRecord
  CATEGORIES = {
    pre_due: "pre_due",
    overdue: "overdue"
  }.freeze
  STATUSES = {
    sent: "sent",
    failed: "failed"
  }.freeze
  TONES = {
    friendly: "friendly",
    neutral: "neutral",
    direct: "direct",
    firm: "firm",
    final: "final"
  }.freeze

  belongs_to :account, inverse_of: :invoice_reminders
  belongs_to :invoice, inverse_of: :invoice_reminders
  belongs_to :invoice_schedule, optional: true, inverse_of: :invoice_reminders

  enum :category, CATEGORIES, prefix: true, validate: true
  enum :status, STATUSES, prefix: true, validate: true
  enum :tone, TONES, prefix: true, validate: { allow_nil: true }

  validates :stage_key, presence: true
  validates :stage_key, uniqueness: { scope: :invoice_id }
  validates :invoice_schedule_id, uniqueness: { scope: :invoice_id }, allow_nil: true
  validates :day_offset, numericality: { only_integer: true, greater_than: 0 }
  validate :account_matches_invoice
  validate :invoice_schedule_matches_account
  validate :stage_key_matches_category_and_day_offset

  private
    def account_matches_invoice
      return if account.blank? || invoice.blank? || account == invoice.account

      errors.add(:account, "must match invoice account")
    end

    def invoice_schedule_matches_account
      return if account.blank? || invoice_schedule.blank? || account == invoice_schedule.account

      errors.add(:invoice_schedule, "must belong to the same account")
    end

    def stage_key_matches_category_and_day_offset
      return if category.blank? || day_offset.blank? || stage_key.blank?
      return if stage_key == "#{category}_#{day_offset}"

      errors.add(:stage_key, "must match category and day offset")
    end
end

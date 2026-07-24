class InvoiceReminderSuppression < ApplicationRecord
  REASONS = {
    recent_outbound_message: "recent_outbound_message",
    active_payment_promise: "active_payment_promise",
    active_collection_hold: "active_collection_hold"
  }.freeze

  belongs_to :account, inverse_of: :invoice_reminder_suppressions
  belongs_to :invoice, inverse_of: :invoice_reminder_suppressions
  belongs_to :invoice_schedule,
    optional: true,
    inverse_of: :invoice_reminder_suppressions

  enum :category, InvoiceReminder::CATEGORIES, prefix: true, validate: true
  enum :reason, REASONS, prefix: true, validate: true

  validates :stage_key, presence: true
  validates :stage_key, uniqueness: { scope: :invoice_id }
  validates :invoice_schedule_id, uniqueness: { scope: :invoice_id }, allow_nil: true
  validates :day_offset, numericality: { only_integer: true, greater_than: 0 }
  validates :suppressed_at, presence: true
  validate :account_matches_invoice
  validate :invoice_schedule_matches_account
  validate :stage_key_matches_category_and_day_offset

  class << self
    def for_stage(stage)
      where(stage_key: stage.key).or(where(invoice_schedule: stage))
    end

    def record_for!(invoice:, stage:, reason:, suppressed_at: Time.current)
      invoice.invoice_reminder_suppressions.create!(
        account: invoice.account,
        invoice_schedule: stage,
        category: stage.category,
        day_offset: stage.day_offset,
        stage_key: stage.key,
        reason:,
        suppressed_at:
      )
    end
  end

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

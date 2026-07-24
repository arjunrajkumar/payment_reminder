class InvoiceReminder < ApplicationRecord
  CATEGORIES = {
    pre_due: "pre_due",
    overdue: "overdue"
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
  belongs_to :conversation_message, inverse_of: :invoice_reminder
  belongs_to :invoice_schedule, optional: true, inverse_of: :invoice_reminders
  has_many :notification_deliveries,
    class_name: "InvoiceReminderNotificationDelivery",
    dependent: :destroy,
    inverse_of: :invoice_reminder

  enum :category, CATEGORIES, prefix: true, validate: true
  enum :tone, TONES, prefix: true, validate: { allow_nil: true }

  delegate :status,
    :status_pending?,
    :status_sent?,
    :status_failed?,
    :sent_at,
    :provider_message_id,
    :provider_thread_id,
    :failure_reason,
    to: :conversation_message

  validates :stage_key, presence: true
  validates :stage_key, uniqueness: { scope: :invoice_id }
  validates :conversation_message_id, uniqueness: true
  validates :invoice_schedule_id, uniqueness: { scope: :invoice_id }, allow_nil: true
  validates :day_offset, numericality: { only_integer: true, greater_than: 0 }
  validate :account_matches_invoice
  validate :conversation_message_matches_reminder
  validate :invoice_schedule_matches_account
  validate :stage_key_matches_category_and_day_offset
  validate :terminal_snapshot_is_immutable, on: :update

  def self.for_stage(stage)
    where(stage_key: stage.key).or(where(invoice_schedule: stage))
  end

  def self.fail_owned_delivery_for_stage!(
    invoice:,
    stage_key:,
    delivery_job_id:,
    failure_reason:
  )
    message = includes(:conversation_message)
      .find_by(invoice:, stage_key:)
      &.conversation_message

    return false unless message

    message.mark_delivery_failed!(
      job_id: delivery_job_id,
      failure_reason:,
      delivery_uncertain: message.provider_delivery_claimed?
    )
  end

  def terminal_stage?
    return terminal_at_delivery? unless terminal_at_delivery.nil?
    return false unless category_overdue?

    stage = invoice_schedule || account.invoice_schedules.find_by(
      category:,
      day_offset:,
      kind: invoice.customer.payer_segment
    )
    stage&.terminal? || false
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

    def conversation_message_matches_reminder
      return if conversation_message.blank? || invoice.blank? || account.blank?

      errors.add(:conversation_message, "must belong to the same invoice") unless conversation_message.invoice == invoice
      errors.add(:conversation_message, "must belong to the same account") unless conversation_message.account == account
      errors.add(:conversation_message, "must be an outbound scheduled reminder") unless
        conversation_message.direction_outbound? && conversation_message.kind_scheduled_reminder?
    end

    def stage_key_matches_category_and_day_offset
      return if category.blank? || day_offset.blank? || stage_key.blank?
      return if stage_key == "#{category}_#{day_offset}"

      errors.add(:stage_key, "must match category and day offset")
    end

    def terminal_snapshot_is_immutable
      change = terminal_at_delivery_change_to_be_saved
      return unless change && !change.first.nil?

      errors.add(:terminal_at_delivery, "cannot be changed after reservation")
    end
end

class NotificationSubscription < ApplicationRecord
  EVENTS = %w[
    invoice_reminder
    invoice_reminder_stopped
  ].index_by(&:itself).freeze

  belongs_to :user, inverse_of: :notification_subscriptions

  enum :event, EVENTS, prefix: true, validate: true

  validates :event, uniqueness: { scope: :user_id }

  scope :email_enabled, -> { where(email: true) }
end

class OutboundEmailConnection < ApplicationRecord
  include Gmailable

  belongs_to :account, inverse_of: :outbound_email_connection

  attribute :scopes, default: -> { [] }

  encrypts :access_token, :refresh_token

  enum :provider, { gmail: "gmail" }, validate: true
  enum :status, {
    pending: "pending",
    active: "active",
    disconnected: "disconnected",
    errored: "errored"
  }, validate: true

  validates :account_id, uniqueness: true
  validates :connected_email,
    presence: true,
    format: { with: URI::MailTo::EMAIL_REGEXP },
    length: { maximum: 254 }
  validates :access_token, :refresh_token, presence: true, if: :active?
  normalizes :connected_email, with: ->(value) { value.strip.downcase.presence }

  def disconnect!
    transaction do
      account.update!(automatic_invoice_reminders_enabled: false)
      update!(
        status: :disconnected,
        access_token: nil,
        refresh_token: nil,
        token_expires_at: nil,
        last_error: nil
      )
    end
  end

  def mark_errored!(error)
    update!(status: :errored, last_error: error.message)
  end

  def sender_matches?(address)
    connected_email.present? && address.present? && connected_email.casecmp?(address)
  end
end

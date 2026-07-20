class ExternalIdentity < ApplicationRecord
  belongs_to :identity

  enum :provider, {
    xero: "xero"
  }

  normalizes :email_address, with: ->(value) { value.strip.downcase.presence }

  validates :provider, :subject, presence: true
  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :subject, uniqueness: { scope: :provider }
  validates :provider, uniqueness: { scope: :identity_id }
  validate :provider_and_subject_are_immutable, on: :update

  private
    def provider_and_subject_are_immutable
      errors.add(:provider, "cannot be changed") if will_save_change_to_provider?
      errors.add(:subject, "cannot be changed") if will_save_change_to_subject?
    end
end

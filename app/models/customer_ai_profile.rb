class CustomerAiProfile < ApplicationRecord
  belongs_to :account, inverse_of: :customer_ai_profiles
  belongs_to :customer, inverse_of: :customer_ai_profile
  belongs_to :active_guidance_revision,
    class_name: "CustomerAiGuidanceRevision",
    optional: true
  has_many :guidance_revisions,
    -> { order(:revision_number) },
    class_name: "CustomerAiGuidanceRevision",
    dependent: :destroy,
    inverse_of: :customer_ai_profile

  validates :customer_id, uniqueness: { scope: :account_id }
  validate :customer_matches_account
  validate :active_revision_matches_profile

  private
    def customer_matches_account
      return if customer.blank? || account.blank? || customer.account_id == account_id

      errors.add(:customer, "must belong to the profile account")
    end

    def active_revision_matches_profile
      return if active_guidance_revision.blank?
      return if active_guidance_revision.customer_ai_profile_id == id &&
        active_guidance_revision.status_active?

      errors.add(:active_guidance_revision, "must be this profile's active revision")
    end
end

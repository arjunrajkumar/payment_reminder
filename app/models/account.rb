class Account < ApplicationRecord
  has_many :invoice_integrations, dependent: :destroy
  has_many :users, dependent: :destroy

  before_create :assign_external_account_id

  validates :name, presence: true

  class << self
    def create_with_owner(account:, owner:)
      create!(**account).tap do |account|
        account.users.create!(role: :system, name: "System")
        account.users.create!(**owner.with_defaults(role: :owner, verified_at: Time.current))
      end
    end
  end

  def slug
    "/#{AccountSlug.encode(external_account_id)}"
  end

  def system_user
    users.find_by!(role: :system)
  end

  def active?
    true
  end

  private
    def assign_external_account_id
      self.external_account_id ||= ExternalIdSequence.next
    end
end

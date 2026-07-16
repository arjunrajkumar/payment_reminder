class Account < ApplicationRecord
  has_many :invoice_sources, dependent: :destroy
  has_many :customers, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :users, dependent: :destroy
  has_many :customer_segments, dependent: :destroy, inverse_of: :account

  include CustomerSegments

  before_create :assign_external_account_id

  validates :name, presence: true

  class << self
    def create_with_owner(account:, owner:)
      transaction do
        create!(**account).tap do |account|
          account.users.create!(role: :system, name: "System")
          account.users.create!(**owner.with_defaults(role: :owner, verified_at: Time.current))
        end
      end
    end
  end

  def slug
    "/#{AccountSlug.encode(external_account_id)}"
  end

  def active?
    true
  end

  private
    def assign_external_account_id
      self.external_account_id ||= ExternalIdSequence.next
    end
end

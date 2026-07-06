class User < ApplicationRecord
  include User::Role

  belongs_to :account
  belongs_to :identity, optional: true

  validates :name, presence: true

  scope :alphabetically, -> { order(:name, :id) }

  def deactivate
    transaction do
      update! active: false, identity: nil
    end
  end

  def initials
    name.to_s.scan(/\b\w/).join.upcase
  end

  def title
    [ name, identity&.email_address ].compact_blank.join(" - ")
  end

  def setup?
    name != identity&.email_address
  end

  def verified?
    verified_at.present?
  end

  def verify
    update!(verified_at: Time.current) unless verified?
  end
end

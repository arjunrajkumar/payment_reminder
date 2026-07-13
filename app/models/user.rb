class User < ApplicationRecord
  include User::Role

  belongs_to :account
  belongs_to :identity, optional: true

  validates :name, presence: true

  def deactivate
    transaction do
      update! active: false, identity: nil
    end
  end
end

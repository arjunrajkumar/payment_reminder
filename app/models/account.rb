class Account < ApplicationRecord
  has_many :users, dependent: :destroy, inverse_of: :account

  validates :name, presence: true
end

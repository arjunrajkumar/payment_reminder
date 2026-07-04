class Account < ApplicationRecord
  has_many :invoice_integrations, dependent: :destroy, inverse_of: :account
  has_many :users, dependent: :destroy, inverse_of: :account

  validates :name, presence: true
end

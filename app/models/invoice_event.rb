class InvoiceEvent < ApplicationRecord
  belongs_to :invoice

  attribute :metadata, default: -> { {} }

  validates :situation, :asked_at, presence: true
end

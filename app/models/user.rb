class User < ApplicationRecord
  belongs_to :account, inverse_of: :users

  normalizes :email, with: -> { _1.strip.downcase }

  validates :name, :email, presence: true
  validates :email, uniqueness: { case_sensitive: false }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order("LOWER(name)") }
  scope :filtered_by, ->(query) { where("name like ?", "%#{query}%") }

  def initials
    name.to_s.scan(/\b\w/).join.upcase
  end

  def title
    [ name, email ].compact_blank.join(" - ")
  end
end

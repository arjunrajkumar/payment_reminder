class Invoice < ApplicationRecord
  STATUSES = {
    pending: "pending",
    open: "open",
    paid: "paid",
    uncollectible: "uncollectible",
    void: "void",
    unknown: "unknown"
  }.freeze
  ISSUED_STATUSES = STATUSES.values_at(:open, :paid, :uncollectible).freeze

  belongs_to :account, inverse_of: :invoices
  belongs_to :invoice_source, inverse_of: :invoices
  belongs_to :customer, inverse_of: :invoices
  attribute :provider_data, default: -> { {} }
  attribute :raw_data, default: -> { {} }

  enum :status, STATUSES, prefix: true, validate: true

  validates :external_id, presence: true
  validates :external_id, uniqueness: { scope: :invoice_source_id }

  scope :recent, -> { order(issued_on: :desc, due_on: :desc, created_at: :desc) }
  scope :issued, -> { where(status: ISSUED_STATUSES) }
  scope :outstanding, -> { where(status: STATUSES.fetch(:open)).where("amount_due > 0") }
  scope :paid, -> { where(status: STATUSES.fetch(:paid)) }
  scope :uncollectible, -> { where(status: STATUSES.fetch(:uncollectible)) }
  scope :overdue, ->(as_of:) { outstanding.where(due_on: ...as_of) }

  def issued?
    status.in?(ISSUED_STATUSES)
  end

  def outstanding?
    status_open? && amount_due.to_d.positive?
  end

  def open?
    status_open?
  end

  def paid?
    status_paid?
  end

  def uncollectible?
    status_uncollectible?
  end

  def overdue?(as_of:)
    outstanding? && due_on.present? && due_on < as_of
  end
end

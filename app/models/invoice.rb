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
  has_many :payment_promises,
    dependent: :destroy,
    inverse_of: :invoice
  has_many :invoice_reminders,
    -> { order(created_at: :desc, id: :desc) },
    dependent: :destroy,
    inverse_of: :invoice
  has_many :invoice_reminder_suppressions,
    -> { order(created_at: :desc, id: :desc) },
    dependent: :destroy,
    inverse_of: :invoice
  has_many :collection_holds,
    -> { order(placed_at: :desc, id: :desc) },
    dependent: :destroy,
    inverse_of: :invoice
  before_destroy :destroy_ai_evidence_for_parent, prepend: true
  before_destroy :destroy_conversation_messages_in_dependency_order
  has_many :conversation_messages,
    -> { order(created_at: :desc, id: :desc) },
    dependent: :destroy,
    inverse_of: :invoice
  has_one :conversation, dependent: :destroy, inverse_of: :invoice
  attribute :provider_data, default: -> { {} }
  attribute :raw_data, default: -> { {} }

  enum :status, STATUSES, prefix: true, validate: true

  before_validation :set_completed_on
  after_update :synchronize_conversation_customer, if: :saved_change_to_customer_id?

  validates :external_id, presence: true
  validates :external_id, uniqueness: { scope: :invoice_source_id }
  validate :account_matches_invoice_source
  validate :account_matches_customer
  validate :invoice_source_matches_customer

  scope :recent, -> { order(issued_on: :desc, due_on: :desc, created_at: :desc) }
  scope :issued, -> { where(status: ISSUED_STATUSES) }
  scope :open, -> { where(status: :open) }
  scope :outstanding, -> { where(status: :open).where("amount_due > 0") }
  scope :paid, -> { where(status: :paid) }
  scope :uncollectible, -> { where(status: :uncollectible) }
  scope :overdue, ->(as_of:) { outstanding.where(due_on: ...as_of) }

  scope :for_index, ->(as_of: Date.current) do
    priority = Arel::Nodes::Case.new
      .when(
        arel_table[:status].eq("open")
          .and(arel_table[:amount_due].gt(0))
          .and(arel_table[:due_on].lt(as_of))
      ).then(0)
      .when(arel_table[:status].eq("uncollectible")).then(1)
      .when(arel_table[:status].eq("unknown")).then(2)
      .when(arel_table[:status].eq("open").and(arel_table[:amount_due].gt(0))).then(3)
      .when(arel_table[:status].eq("open")).then(4)
      .when(arel_table[:status].eq("pending")).then(5)
      .when(arel_table[:status].eq("paid")).then(6)
      .when(arel_table[:status].eq("void")).then(7)
      .else(8)

    eager_load(:customer)
      .preload(invoice_reminders: :conversation_message)
      .order(priority.asc, Customer.arel_table[:name].asc, arel_table[:id].asc)
  end

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

  def status_as_of(as_of:)
    return "overdue" if overdue?(as_of: as_of)
    return "outstanding" if outstanding?

    status
  end

  def active_collection_holds
    collection_holds.status_active
  end

  def collection_held?
    active_collection_holds.exists?
  end

  def online_invoice_url
    provider_data["online_invoice_url"].presence
  end

  def invoice_pdf_url
    provider_data["invoice_pdf_url"].presence
  end

  private
    def destroy_ai_evidence_for_parent
      ConversationAi::ParentDeletion.destroy_interpretations!(
        ConversationInterpretation.where(invoice_id: id)
      )
    end

    def destroy_conversation_messages_in_dependency_order
      ConversationMessage.destroy_in_dependency_order!(conversation_messages)
    end

    def synchronize_conversation_customer
      association(:conversation).reset
      conversation&.update!(customer:)
    end

    def set_completed_on
      if status_paid?
        self.completed_on = paid_on
      elsif status_uncollectible?
        self.completed_on ||= completed_on_in_database if status_in_database == "uncollectible"
        self.completed_on ||= Date.current
      else
        self.completed_on = nil
      end
    end

    def account_matches_invoice_source
      return if account.blank? || invoice_source.blank? || account == invoice_source.account

      errors.add(:account, "must match invoice source account")
    end

    def account_matches_customer
      return if account.blank? || customer.blank? || account == customer.account

      errors.add(:account, "must match customer account")
    end

    def invoice_source_matches_customer
      return if invoice_source.blank? || customer.blank? || invoice_source == customer.invoice_source

      errors.add(:invoice_source, "must match customer invoice source")
    end
end

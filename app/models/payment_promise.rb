class PaymentPromise < ApplicationRecord
  STATUSES = {
    active: "active",
    fulfilled: "fulfilled",
    followed_up: "followed_up",
    follow_up_failed: "follow_up_failed",
    superseded: "superseded",
    cancelled: "cancelled"
  }.freeze

  belongs_to :account, inverse_of: :payment_promises
  belongs_to :invoice, inverse_of: :payment_promises
  belongs_to :source_message,
    class_name: "ConversationMessage",
    inverse_of: :payment_promise
  belongs_to :follow_up_message,
    class_name: "ConversationMessage",
    inverse_of: :payment_promise_follow_up,
    optional: true

  enum :status, STATUSES, prefix: true, validate: true

  validates :promised_on, :follow_up_on, presence: true
  validates :source_message_id, uniqueness: true
  validates :follow_up_message_id, uniqueness: true, allow_nil: true
  validate :account_matches_invoice
  validate :source_message_matches_promise
  validate :source_message_is_received_inbound
  validate :follow_up_message_matches_promise
  validate :follow_up_message_has_expected_kind
  validate :only_one_active_promise
  validate :dates_fit_database

  before_validation :synchronize_derived_fields
  before_save :synchronize_derived_fields

  scope :due_for_follow_up, ->(on: Date.current) do
    status_active.where(follow_up_on: ..on)
  end

  class << self
    def record!(invoice:, source_message:, promised_on:)
      recorded_promise = nil

      transaction do
        invoice.with_lock do
          recorded_promise = invoice.payment_promises.find_by(source_message:)

          unless recorded_promise
            invoice.payment_promises.status_active.find_each do |promise|
              promise.update!(status: :superseded)
            end

            recorded_promise = invoice.payment_promises.create!(
              account: invoice.account,
              source_message:,
              promised_on:
            )
          end
        end
      end

      recorded_promise
    end
  end

  def fulfill!
    resolve_as!(:fulfilled)
  end

  def followed_up!
    resolve_as!(:followed_up)
  end

  def follow_up_failed!
    resolve_as!(:follow_up_failed)
  end

  def cancel!
    resolve_as!(:cancelled)
  end

  def resolve_follow_up!(as:)
    resolution = as.to_sym
    unless resolution.in?(%i[fulfilled followed_up follow_up_failed cancelled])
      raise ArgumentError, "Unsupported payment promise resolution: #{as.inspect}"
    end

    resolve_as!(resolution)
  end

  def record_follow_up_sent!(
    job_id:,
    sent_at: Time.current,
    provider_message_id:,
    provider_thread_id: nil
  )
    record_follow_up_delivery(
      as: :followed_up,
      job_id:,
      message_attributes: {
        status: :sent,
        sent_at:,
        provider_message_id:,
        provider_thread_id:,
        failure_reason: nil,
        delivery_uncertain: false
      }
    )
  end

  def record_follow_up_failed!(
    job_id:,
    failure_reason:,
    delivery_uncertain: false
  )
    record_follow_up_delivery(
      as: :follow_up_failed,
      job_id:,
      message_attributes: {
        status: :failed,
        sent_at: nil,
        provider_message_id: nil,
        provider_thread_id: nil,
        failure_reason:,
        delivery_uncertain:
      }
    )
  end

  def confirm_imported_follow_up!(message:)
    invoice.with_lock do
      reload
      next unless follow_up_message_id == message.id
      next unless status_active? || status_follow_up_failed?

      update!(status: :followed_up)
    end
    self
  end

  private
    def record_follow_up_delivery(as:, job_id:, message_attributes:)
      recorded = false

      self.class.transaction do
        invoice.with_lock do
          reload
          message = follow_up_message
          next unless status_active? && message

          message.with_lock do
            next unless follow_up_message_id == message.id
            next unless message.delivery_owned_by?(job_id)

            message.update!(message_attributes)
            update!(status: as)
            recorded = true
          end
        end
      end

      recorded
    end

    def resolve_as!(new_status)
      with_lock do
        update!(status: new_status) if status_active?
      end
    end

    def synchronize_derived_fields
      self.follow_up_on = promised_on.next_day if promised_on.present? &&
        promised_on <= Date.new(9999, 12, 30)
      self.active_invoice_id = status_active? ? invoice_id : nil
    end

    def dates_fit_database
      supported = Date.new(1000, 1, 1)..Date.new(9999, 12, 31)
      errors.add(:promised_on, "is outside the supported range") if
        promised_on.present? && !supported.cover?(promised_on)
      errors.add(:follow_up_on, "is outside the supported range") if
        follow_up_on.present? && !supported.cover?(follow_up_on)
    end

    def account_matches_invoice
      return if account.blank? || invoice.blank? || account == invoice.account

      errors.add(:account, "must match invoice account")
    end

    def source_message_matches_promise
      return if source_message.blank? || account.blank? || invoice.blank?
      return if source_message.account == account && source_message.invoice == invoice

      errors.add(:source_message, "must belong to the same account and invoice")
    end

    def source_message_is_received_inbound
      return if source_message.blank?
      return if source_message.direction_inbound? && source_message.status_received?

      errors.add(:source_message, "must be a received inbound message")
    end

    def follow_up_message_matches_promise
      return if follow_up_message.blank? || account.blank? || invoice.blank?
      return if follow_up_message.account == account && follow_up_message.invoice == invoice

      errors.add(:follow_up_message, "must belong to the same account and invoice")
    end

    def follow_up_message_has_expected_kind
      return if follow_up_message.blank?
      return if follow_up_message.direction_outbound? && follow_up_message.kind_promise_follow_up?

      errors.add(:follow_up_message, "must be an outbound promise follow-up")
    end

    def only_one_active_promise
      return unless status_active? && invoice_id.present?

      active_promises = self.class.where(active_invoice_id: invoice_id)
      active_promises = active_promises.where.not(id:) if persisted?
      return unless active_promises.exists?

      errors.add(:invoice, "already has an active payment promise")
    end
end

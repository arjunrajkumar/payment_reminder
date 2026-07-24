class InvoiceReminderNotificationDelivery < ApplicationRecord
  STALE_AFTER = 30.minutes
  BUILD_STALE_AFTER = 30.minutes
  RETRY_RESERVATION_STALE_AFTER = 1.hour
  MAX_TRANSPORT_ATTEMPTS = 5
  MAX_BUILD_ATTEMPTS = 5
  MAX_SCHEDULING_FAILURES = 5
  STATUSES = {
    pending: "pending",
    delivering: "delivering",
    delivered: "delivered",
    uncertain: "uncertain",
    failed: "failed",
    canceled: "canceled"
  }.freeze

  belongs_to :account, inverse_of: :invoice_reminder_notification_deliveries
  belongs_to :invoice_reminder,
    inverse_of: :notification_deliveries
  belongs_to :recipient_user,
    class_name: "User",
    inverse_of: :invoice_reminder_notification_deliveries,
    optional: true

  enum :status, STATUSES, prefix: true, validate: true

  normalizes :attempt_token,
    :build_token,
    :retry_job_id,
    with: ->(token) { token.to_s.strip.presence }

  validates :event_name, :recipient_email, :recipient_user_snapshot_id,
    presence: true
  validates :attempts,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: MAX_TRANSPORT_ATTEMPTS
    }
  validates :build_attempts,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: MAX_BUILD_ATTEMPTS
    }
  validates :scheduling_failures,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :recipient_user_snapshot_id,
    uniqueness: { scope: %i[invoice_reminder_id event_name] }
  validate :ownership_matches

  scope :terminal, -> {
    where(status: %i[delivered uncertain failed canceled])
  }

  def claim_for_build!(
    build_token:,
    retry_job_id: nil,
    allow_unowned_retry: false,
    at: Time.current
  )
    result = false
    normalized_build_token = build_token.to_s.strip.presence
    return false unless normalized_build_token

    with_lock do
      return false unless status_pending?
      return :busy if self.build_token.present?
      return :busy unless delivery_owner_matches?(
        retry_job_id:,
        allow_unowned_retry:
      )

      if attempts >= MAX_TRANSPORT_ATTEMPTS
        update!(
          status: :failed,
          failed_at: at,
          terminal_reason: "transport_attempts_exhausted",
          retry_job_id: nil,
          retry_enqueued_at: nil,
          next_retry_at: nil
        )
        result = :failed
      elsif build_attempts >= MAX_BUILD_ATTEMPTS
        update!(
          status: :failed,
          failed_at: at,
          terminal_reason: "build_attempts_exhausted",
          retry_job_id: nil,
          retry_enqueued_at: nil,
          next_retry_at: nil
        )
        result = :failed
      else
        update!(
          build_token: normalized_build_token,
          build_started_at: at
        )
        result = :claimed
      end
    end
    result
  end

  def claim_for_delivery!(
    attempt_token:,
    build_token: nil,
    retry_job_id: nil,
    allow_unowned_retry: false,
    at: Time.current
  )
    claimed = false
    with_lock do
      if status_pending? &&
          attempts < MAX_TRANSPORT_ATTEMPTS &&
          build_owner_matches?(build_token) &&
          delivery_owner_matches?(
            retry_job_id:,
            allow_unowned_retry:
          )
        update!(
          status: :delivering,
          attempt_token:,
          build_token: nil,
          build_started_at: nil,
          retry_job_id: nil,
          retry_enqueued_at: nil,
          next_retry_at: nil,
          delivery_started_at: at,
          attempts: attempts + 1,
          last_error_class: nil,
          last_error_message: nil
        )
        claimed = true
      end
    end
    claimed
  end

  def record_delivered!(attempt_token:, at: Time.current)
    with_lock do
      return false unless claim_owned_by?(attempt_token)

      update!(
        status: :delivered,
        delivered_at: at,
        attempt_token: nil,
        last_error_class: nil,
        last_error_message: nil
      )
    end
    true
  end

  def record_known_failure!(
    attempt_token:,
    error:,
    retry_at:,
    at: Time.current
  )
    result = false
    with_lock do
      return false unless claim_owned_by?(attempt_token)

      attributes = {
        attempt_token: nil,
        delivery_started_at: nil,
        last_error_class: error.class.name,
        last_error_message: error.message
      }
      if attempts >= MAX_TRANSPORT_ATTEMPTS
        attributes.merge!(
          status: :failed,
          failed_at: at,
          terminal_reason: "transport_attempts_exhausted",
          next_retry_at: nil
        )
        result = :failed
      else
        attributes.merge!(
          status: :pending,
          next_retry_at: retry_at
        )
        result = :pending
      end
      update!(attributes)
    end
    result
  end

  def record_uncertain!(attempt_token:, error:)
    with_lock do
      return false unless claim_owned_by?(attempt_token)

      update!(
        status: :uncertain,
        attempt_token: nil,
        retry_job_id: nil,
        retry_enqueued_at: nil,
        next_retry_at: nil,
        last_error_class: error.class.name,
        last_error_message: error.message
      )
    end
    true
  end

  def record_build_failure!(
    build_token:,
    error:,
    retry_at:,
    at: Time.current
  )
    result = false
    with_lock do
      return false unless status_pending?
      return false unless build_owned_by?(build_token)

      failures = build_attempts + 1
      attributes = {
        build_attempts: failures,
        build_token: nil,
        build_started_at: nil,
        retry_job_id: nil,
        retry_enqueued_at: nil,
        last_error_class: error.class.name,
        last_error_message: error.message
      }
      if failures >= MAX_BUILD_ATTEMPTS
        attributes.merge!(
          status: :failed,
          failed_at: at,
          terminal_reason: "build_attempts_exhausted",
          next_retry_at: nil
        )
        result = :failed
      else
        attributes[:next_retry_at] = retry_at
        result = :pending
      end
      update!(attributes)
    end
    result
  end

  def reserve_retry!(job_id:, run_at:, at: Time.current)
    reserved = false
    with_lock do
      if status_pending? &&
          attempts < MAX_TRANSPORT_ATTEMPTS &&
          build_attempts < MAX_BUILD_ATTEMPTS &&
          build_token.nil? &&
          retry_job_id.nil?
        update!(
          retry_job_id: job_id,
          retry_enqueued_at: at,
          next_retry_at: run_at
        )
        reserved = true
      end
    end
    reserved
  end

  def record_scheduling_failure!(job_id:, error:, at: Time.current)
    with_lock do
      return false unless status_pending?
      return false unless retry_owned_by?(job_id)

      failures = scheduling_failures + 1
      attributes = {
        scheduling_failures: failures,
        retry_job_id: nil,
        retry_enqueued_at: nil,
        last_error_class: error.class.name,
        last_error_message: error.message
      }
      if failures >= MAX_SCHEDULING_FAILURES
        attributes.merge!(
          status: :failed,
          failed_at: at,
          terminal_reason: "retry_scheduling_exhausted",
          next_retry_at: nil
        )
      end
      update!(attributes)
    end
    true
  end

  def record_failed!(error:, reason: "retry_exhausted", at: Time.current)
    with_lock do
      return false unless status_pending?

      update!(
        status: :failed,
        failed_at: at,
        terminal_reason: reason,
        build_token: nil,
        build_started_at: nil,
        retry_job_id: nil,
        retry_enqueued_at: nil,
        next_retry_at: nil,
        last_error_class: error.class.name,
        last_error_message: error.message
      )
    end
    true
  end

  def record_canceled!(reason:, at: Time.current)
    with_lock do
      return false unless status_pending?

      update!(
        status: :canceled,
        canceled_at: at,
        terminal_reason: reason,
        build_token: nil,
        build_started_at: nil,
        retry_job_id: nil,
        retry_enqueued_at: nil,
        next_retry_at: nil
      )
    end
    true
  end

  def adjudicate_stale_claim!(before:)
    with_lock do
      return false unless status_delivering?
      return false unless delivery_started_at && delivery_started_at <= before

      update!(
        status: :uncertain,
        attempt_token: nil,
        retry_job_id: nil,
        retry_enqueued_at: nil,
        next_retry_at: nil,
        terminal_reason: "stale_delivery_claim",
        last_error_class: "UnconfirmedNotificationHandoff",
        last_error_message: "A notification handoff did not record an outcome."
      )
    end
    true
  end

  def release_stale_retry_reservation!(before:)
    released = false
    with_lock do
      if status_pending? &&
          retry_job_id.present? &&
          retry_enqueued_at &&
          retry_enqueued_at <= before
        update!(
          retry_job_id: nil,
          retry_enqueued_at: nil
        )
        released = true
      end
    end
    released
  end

  def release_stale_build!(before:)
    released = false
    with_lock do
      if status_pending? &&
          build_token.present? &&
          build_started_at &&
          build_started_at <= before
        update!(
          build_token: nil,
          build_started_at: nil,
          retry_job_id: nil,
          retry_enqueued_at: nil
        )
        released = true
      end
    end
    released
  end

  private
    def build_owner_matches?(token)
      build_token.nil? || build_owned_by?(token)
    end

    def build_owned_by?(token)
      build_token.present? &&
        ActiveSupport::SecurityUtils.secure_compare(
          build_token,
          token.to_s
        )
    end

    def delivery_owner_matches?(retry_job_id:, allow_unowned_retry:)
      if retry_job_id.present?
        retry_owned_by?(retry_job_id)
      else
        self.retry_job_id.nil? &&
          (attempts.zero? || allow_unowned_retry)
      end
    end

    def retry_owned_by?(job_id)
      retry_job_id.present? &&
        ActiveSupport::SecurityUtils.secure_compare(
          retry_job_id,
          job_id.to_s
        )
    end

    def claim_owned_by?(token)
      status_delivering? &&
        attempt_token.present? &&
        ActiveSupport::SecurityUtils.secure_compare(attempt_token, token.to_s)
    end

    def ownership_matches
      return if account.blank? || invoice_reminder.blank?
      return if invoice_reminder.account == account &&
        (recipient_user.blank? || recipient_user.account == account)

      errors.add(:account, "must match the reminder and recipient")
    end
end

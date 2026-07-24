class EmailMessageReceipt < ApplicationRecord
  class ClaimLost < StandardError; end

  ENQUEUE_RESERVATION_STALE_AFTER = 1.hour
  POST_PROCESSING_STALE_AFTER = 1.hour

  DIRECTIONS = {
    inbound: "inbound",
    outbound: "outbound"
  }.freeze
  STATUSES = {
    pending: "pending",
    processing: "processing",
    processed: "processed",
    ignored: "ignored",
    failed: "failed"
  }.freeze

  belongs_to :account, inverse_of: :email_message_receipts
  belongs_to :email_connection, inverse_of: :email_message_receipts
  belongs_to :conversation_message,
    optional: true,
    inverse_of: :email_message_receipt

  enum :direction, DIRECTIONS, prefix: true, validate: { allow_nil: true }
  enum :status, STATUSES, prefix: true, validate: true

  attribute :metadata, default: -> { {} }

  before_validation :capture_provider_account_id, on: :create

  normalizes :provider_message_id,
    :provider_thread_id,
    :provider_history_id,
    :provider_account_id,
    :processing_job_id,
    :processing_enqueued_job_id,
    :post_processing_job_id,
    :post_processing_enqueued_job_id,
    with: ->(id) { id.to_s.strip.presence }

  validates :provider_account_id, presence: true
  validates :provider_message_id,
    presence: true,
    uniqueness: { scope: %i[email_connection_id provider_account_id] }
  validates :discovered_at, presence: true
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :email_connection_generation,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :metadata, exclusion: { in: [ nil ], message: "can't be blank" }
  validate :account_matches_email_connection
  validate :conversation_message_matches_account
  validate :conversation_message_matches_mailbox_identity
  validate :provider_account_id_is_immutable, on: :update
  validate :email_connection_generation_is_immutable, on: :update

  scope :due_for_processing, ->(at: Time.current) do
    where(status: :pending)
      .or(where(status: :failed, next_retry_at: ..at))
  end
  scope :stale_processing, ->(before:) { status_processing.where(processing_started_at: ...before) }
  scope :unfinished_post_processing, -> {
    status_processed.where(post_processing_finalized_at: nil)
  }

  def self.processing_concurrency_key(id)
    identity = where(id:).pick(
      :email_connection_id,
      :provider_account_id,
      :email_connection_generation,
      :provider_thread_id,
      :provider_message_id
    )
    return "receipt-#{id}" unless identity

    connection_id, provider_account_id, generation, thread_id, message_id = identity
    provider_key = thread_id.presence || message_id.presence || id
    Digest::SHA256.hexdigest(
      [ connection_id, provider_account_id, generation, provider_key ].join("\0")
    )
  end

  def reserve_processing_enqueue!(
    job_id:,
    at: Time.current,
    provider_account_id: self.provider_account_id,
    email_connection_generation: self.email_connection_generation
  )
    reserved = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      next unless mailbox_snapshot?(
        provider_account_id:,
        email_connection_generation:
      )
      next unless current_mailbox?
      next unless email_connection.reload.inbound_ready?
      next unless due_for_processing?(at:)
      next if processing_enqueue_reserved?(at:)

      update!(
        processing_enqueued_job_id: normalized_job_id,
        processing_enqueued_at: at
      )
      reserved = true
    end
    reserved
  end

  def release_processing_enqueue!(job_id:)
    released = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      next unless processing_enqueued_job_id == normalized_job_id

      update!(
        processing_enqueued_job_id: nil,
        processing_enqueued_at: nil
      )
      released = true
    end
    released
  end

  def claim!(
    job_id:,
    at: Time.current,
    provider_account_id: self.provider_account_id,
    email_connection_generation: self.email_connection_generation
  )
    claimed = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      next unless mailbox_snapshot?(
        provider_account_id:,
        email_connection_generation:
      )
      next unless current_mailbox?
      next unless email_connection.reload.inbound_ready?
      next unless due_for_processing?(at:)
      next if processing_enqueued_job_id.present? && processing_enqueued_job_id != normalized_job_id

      update!(
        status: :processing,
        attempts: attempts + 1,
        processing_job_id: normalized_job_id,
        processing_started_at: at,
        processing_enqueued_job_id: nil,
        processing_enqueued_at: nil,
        next_retry_at: nil,
        last_error: nil
      )
      claimed = true
    end
    claimed
  end

  def processing_owned_by?(job_id)
    status_processing? && processing_job_id.present? && processing_job_id == job_id.to_s.strip
  end

  def current_mailbox?
    provider_account_id.present? &&
      email_connection_generation.present? &&
      email_connection_id.present? &&
      EmailConnection.where(
        id: email_connection_id,
        provider_account_id:,
        credential_generation: email_connection_generation
      ).exists?
  end

  def mailbox_snapshot?(provider_account_id:, email_connection_generation:)
    self.provider_account_id == provider_account_id.to_s.strip &&
      self.email_connection_generation == email_connection_generation.to_i
  end

  def with_processing_claim!(job_id:)
    connection = email_connection
    connection.with_lock do
      connection.assert_gmail_credentials!(
        provider_account_id:,
        credential_generation: email_connection_generation
      )
      with_lock do
        raise ClaimLost unless processing_owned_by?(job_id) && current_mailbox?

        yield self
      end
    end
  end

  def complete!(job_id:, conversation_message:, direction:, provider_thread_id: nil, metadata: {})
    finish_owned!(job_id:) do
      update!(
        status: :processed,
        conversation_message:,
        direction:,
        provider_thread_id: provider_thread_id.presence || self.provider_thread_id,
        metadata:,
        processed_at: Time.current,
        processing_job_id: nil,
        processing_started_at: nil,
        processing_enqueued_job_id: nil,
        processing_enqueued_at: nil,
        next_retry_at: nil,
        last_error: nil
      )
    end
  end

  def mark_post_processing_finalized!(at: Time.current)
    return true if post_processing_finalized_at?

    updated = self.class.where(
      id:,
      status: :processed,
      post_processing_finalized_at: nil
    ).update_all(
      post_processing_finalized_at: at,
      post_processing_job_id: nil,
      post_processing_started_at: nil,
      post_processing_enqueued_job_id: nil,
      post_processing_enqueued_at: nil
    )
    reload
    updated == 1 || post_processing_finalized_at?
  end

  def reserve_post_processing_enqueue!(job_id:, at: Time.current)
    reserved = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      next unless status_processed? && post_processing_finalized_at.nil?
      next if post_processing_claim_active?(at:)
      next if post_processing_enqueue_reserved?(at:)

      update_columns(
        post_processing_job_id: nil,
        post_processing_started_at: nil,
        post_processing_enqueued_job_id: normalized_job_id,
        post_processing_enqueued_at: at,
        updated_at: at
      )
      reload
      reserved = true
    end
    reserved
  end

  def claim_post_processing!(job_id:, at: Time.current)
    claimed = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      next unless status_processed? && post_processing_finalized_at.nil?
      next if post_processing_job_id.present?
      next if post_processing_enqueued_job_id.present? &&
        post_processing_enqueued_job_id != normalized_job_id

      update_columns(
        post_processing_job_id: normalized_job_id,
        post_processing_started_at: at,
        post_processing_enqueued_job_id: nil,
        post_processing_enqueued_at: nil,
        updated_at: at
      )
      reload
      claimed = true
    end
    claimed
  end

  def complete_post_processing!(job_id:, at: Time.current)
    completed = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      next unless post_processing_job_id == normalized_job_id
      next unless status_processed? && post_processing_finalized_at.nil?

      update_columns(
        post_processing_finalized_at: at,
        post_processing_job_id: nil,
        post_processing_started_at: nil,
        post_processing_enqueued_job_id: nil,
        post_processing_enqueued_at: nil,
        updated_at: at
      )
      reload
      completed = true
    end
    completed
  end

  def reserve_post_processing_retry!(job_id:, at: Time.current)
    reserved = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      next unless status_processed? && post_processing_finalized_at.nil?
      next unless post_processing_job_id == normalized_job_id

      update_columns(
        post_processing_job_id: nil,
        post_processing_started_at: nil,
        post_processing_enqueued_job_id: normalized_job_id,
        post_processing_enqueued_at: at,
        updated_at: at
      )
      reload
      reserved = true
    end
    reserved
  end

  def release_post_processing_ownership!(job_id:)
    released = false
    normalized_job_id = job_id.to_s.strip.presence
    return false unless normalized_job_id

    with_lock do
      owns_claim = post_processing_job_id == normalized_job_id
      owns_enqueue = post_processing_enqueued_job_id == normalized_job_id
      next unless owns_claim || owns_enqueue

      update_columns(
        post_processing_job_id: owns_claim ? nil : post_processing_job_id,
        post_processing_started_at:
          owns_claim ? nil : post_processing_started_at,
        post_processing_enqueued_job_id:
          owns_enqueue ? nil : post_processing_enqueued_job_id,
        post_processing_enqueued_at:
          owns_enqueue ? nil : post_processing_enqueued_at,
        updated_at: Time.current
      )
      reload
      released = true
    end
    released
  end

  def ignore!(job_id:, reason:, direction: nil, provider_thread_id: nil, metadata: {})
    finish_owned!(job_id:) do
      update!(
        status: :ignored,
        direction:,
        provider_thread_id: provider_thread_id.presence || self.provider_thread_id,
        metadata: metadata.merge("reason" => reason.to_s),
        processed_at: Time.current,
        processing_job_id: nil,
        processing_started_at: nil,
        processing_enqueued_job_id: nil,
        processing_enqueued_at: nil,
        next_retry_at: nil,
        last_error: nil
      )
    end
  end

  def fail!(job_id:, error:, retry_at:, retry_job_id: nil)
    finish_owned!(job_id:) do
      update!(
        status: :failed,
        processing_job_id: nil,
        processing_started_at: nil,
        processing_enqueued_job_id: retry_job_id,
        processing_enqueued_at: retry_job_id.present? ? Time.current : nil,
        next_retry_at: retry_at,
        last_error: error.class.name
      )
    end
  end

  def recover_stale_processing!(before:)
    recovered = false
    with_lock do
      next unless status_processing? && processing_started_at.present? && processing_started_at < before

      unless current_mailbox?
        update!(
          status: :ignored,
          metadata: metadata.merge("reason" => "mailbox_replaced"),
          processed_at: Time.current,
          processing_job_id: nil,
          processing_started_at: nil,
          processing_enqueued_job_id: nil,
          processing_enqueued_at: nil,
          next_retry_at: nil,
          last_error: nil
        )
        next
      end

      update!(
        status: :pending,
        processing_job_id: nil,
        processing_started_at: nil,
        processing_enqueued_job_id: nil,
        processing_enqueued_at: nil,
        next_retry_at: nil,
        last_error: "stale_processing_recovered"
      )
      recovered = true
    end
    recovered
  end

  def retire_if_mailbox_replaced!(
    reason: nil,
    expected_provider_account_id: provider_account_id,
    expected_generation: email_connection_generation
  )
    retired = false
    with_lock do
      next unless mailbox_snapshot?(
        provider_account_id: expected_provider_account_id,
        email_connection_generation: expected_generation
      )
      next if current_mailbox?
      next unless unprocessed?

      retire_locked!(reason: reason || stale_mailbox_reason)
      retired = true
    end
    retired
  end

  def retire_unprocessed!(
    reason:,
    expected_provider_account_id: provider_account_id,
    expected_generation: email_connection_generation
  )
    retired = false
    with_lock do
      next unless mailbox_snapshot?(
        provider_account_id: expected_provider_account_id,
        email_connection_generation: expected_generation
      )
      next unless unprocessed?

      retire_locked!(reason:)
      retired = true
    end
    retired
  end

  def retry!
    retried = false
    with_lock do
      next unless status_failed? && next_retry_at.nil? && current_mailbox? && email_connection.reload.inbound_ready?

      update!(
        status: :pending,
        attempts: 0,
        processing_job_id: nil,
        processing_started_at: nil,
        processing_enqueued_job_id: nil,
        processing_enqueued_at: nil,
        next_retry_at: nil,
        last_error: nil
      )
      retried = true
    end
    retried
  end

  def reconsider_unrelated!(generation: email_connection.credential_generation)
    generation = Integer(generation)

    with_current_generation_locked(generation:) do
      next false unless status_ignored?
      next false unless metadata["reason"] == "unrelated"
      next false unless provider_thread_id.present?

      reset_ignored_for_generation_locked!(generation:)
      true
    end
  end

  def reconsider_unrelated_thread_receipts!(anchor_message:)
    return [] if provider_thread_id.blank?
    return [] if anchor_message.blank? || !anchor_message.trusted_matching_anchor?

    self.class.where(
      email_connection_id:,
      provider_account_id:,
      provider_thread_id:,
      status: :ignored
    ).where.not(id:).filter_map do |ignored_receipt|
      if ignored_receipt.reconsider_unrelated!(
        generation: email_connection_generation
      )
        ignored_receipt.id
      end
    end
  end

  def prepare_for_generation!(generation:)
    generation = Integer(generation)

    with_current_generation_locked(generation:) do
      if email_connection_generation == generation
        next true
      elsif unprocessed?
        rebind_unprocessed_locked!(generation:)
        next true
      end
      next false unless status_ignored?
      next false unless %w[
        mailbox_disconnected
        mailbox_replaced
        credentials_replaced
      ].include?(metadata["reason"])

      reset_ignored_for_generation_locked!(generation:)
      true
    end
  end

  def rebind_unprocessed_to_generation!(generation:)
    generation = Integer(generation)

    with_current_generation_locked(generation:) do
      next false unless unprocessed?

      rebind_unprocessed_locked!(generation:)
      true
    end
  end

  private
    def finish_owned!(job_id:)
      finished = false
      with_lock do
        next unless processing_owned_by?(job_id) && current_mailbox?

        yield
        finished = true
      end
      finished
    end

    def account_matches_email_connection
      return if account.blank? || email_connection.blank? || account == email_connection.account

      errors.add(:account, "must match email connection account")
    end

    def capture_provider_account_id
      self.provider_account_id ||= email_connection&.provider_account_id
      self.email_connection_generation ||= email_connection&.credential_generation
    end

    def provider_account_id_is_immutable
      return unless will_save_change_to_provider_account_id?

      errors.add(:provider_account_id, "cannot be changed")
    end

    def email_connection_generation_is_immutable
      return unless will_save_change_to_email_connection_generation?
      return if @generation_rebind_allowed
      return if status_was == "ignored" &&
        %w[mailbox_disconnected mailbox_replaced credentials_replaced].include?(metadata_was["reason"])

      errors.add(:email_connection_generation, "cannot be changed")
    end

    def conversation_message_matches_account
      return if conversation_message.blank? || account.blank? || conversation_message.account == account

      errors.add(:conversation_message, "must belong to the receipt account")
    end

    def conversation_message_matches_mailbox_identity
      return if conversation_message.blank?
      return if conversation_message.provider_account_id == provider_account_id

      errors.add(:conversation_message, "must belong to the receipt mailbox identity")
    end

    def due_for_processing?(at:)
      status_pending? || (status_failed? && next_retry_at.present? && next_retry_at <= at)
    end

    def processing_enqueue_reserved?(at:)
      processing_enqueued_job_id.present? &&
        processing_enqueued_at.present? &&
        processing_enqueued_at >= ENQUEUE_RESERVATION_STALE_AFTER.ago(at)
    end

    def post_processing_claim_active?(at:)
      post_processing_job_id.present? &&
        post_processing_started_at.present? &&
        post_processing_started_at >= POST_PROCESSING_STALE_AFTER.ago(at)
    end

    def post_processing_enqueue_reserved?(at:)
      post_processing_enqueued_job_id.present? &&
        post_processing_enqueued_at.present? &&
        post_processing_enqueued_at >= POST_PROCESSING_STALE_AFTER.ago(at)
    end

    def stale_mailbox_reason
      connection = email_connection
      return :mailbox_disconnected if connection&.provider_account_id.blank?
      return :mailbox_replaced if connection.provider_account_id != provider_account_id

      :credentials_replaced
    end

    def unprocessed?
      status_pending? || status_processing? || status_failed?
    end

    def with_current_generation_locked(generation:)
      connection = EmailConnection.find_by(id: email_connection_id)
      return false unless connection

      connection.with_lock do
        begin
          connection.assert_gmail_credentials!(
            provider_account_id:,
            credential_generation: generation
          )
        rescue EmailConnection::Errors::CredentialChanged
          next false
        end

        with_lock { yield connection }
      end
    end

    def reset_ignored_for_generation_locked!(generation:)
      with_generation_rebind do
        update!(
          email_connection_generation: generation,
          status: :pending,
          direction: nil,
          attempts: 0,
          processed_at: nil,
          processing_job_id: nil,
          processing_started_at: nil,
          processing_enqueued_job_id: nil,
          processing_enqueued_at: nil,
          next_retry_at: nil,
          last_error: nil,
          metadata: {}
        )
      end
    end

    def rebind_unprocessed_locked!(generation:)
      attributes = {
        email_connection_generation: generation,
        processing_job_id: nil,
        processing_started_at: nil,
        processing_enqueued_job_id: nil,
        processing_enqueued_at: nil
      }
      if status_processing?
        attributes.merge!(
          status: :pending,
          next_retry_at: nil,
          last_error: nil
        )
      end
      with_generation_rebind { update!(attributes) }
    end

    def retire_locked!(reason:)
      update!(
        status: :ignored,
        metadata: metadata.merge("reason" => reason.to_s),
        processed_at: Time.current,
        processing_job_id: nil,
        processing_started_at: nil,
        processing_enqueued_job_id: nil,
        processing_enqueued_at: nil,
        next_retry_at: nil,
        last_error: nil
      )
    end

    def with_generation_rebind
      @generation_rebind_allowed = true
      yield
    ensure
      @generation_rebind_allowed = false
    end
end

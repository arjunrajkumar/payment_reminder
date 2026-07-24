class ConversationMessage < ApplicationRecord
  OUTBOUND_CONTACT_COOLDOWN = 48.hours

  def self.destroy_in_dependency_order!(scope)
    remaining = scope.order(:id).to_a.index_by(&:id)

    until remaining.empty?
      referenced_ids = remaining.values
        .filter_map(&:reply_to_message_id)
        .to_set
      leaves = remaining.values.reject { |message| referenced_ids.include?(message.id) }
      if leaves.empty?
        raise ActiveRecord::DeleteRestrictionError,
          "conversation message reply graph cannot be destroyed"
      end

      leaves.each do |message|
        message.destroy!
        remaining.delete(message.id)
      end
    end
  end

  DIRECTIONS = {
    inbound: "inbound",
    outbound: "outbound"
  }.freeze
  KINDS = {
    customer_email: "customer_email",
    manual_email: "manual_email",
    manual_reply: "manual_reply",
    customer_reply: "customer_reply",
    scheduled_reminder: "scheduled_reminder",
    manual_reminder: "manual_reminder",
    due_date_answer: "due_date_answer",
    payment_status_answer: "payment_status_answer",
    outstanding_amount_answer: "outstanding_amount_answer",
    invoice_resend: "invoice_resend",
    payment_promise_acknowledgement: "payment_promise_acknowledgement",
    promise_follow_up: "promise_follow_up",
    dispute_acknowledgement: "dispute_acknowledgement",
    recipient_update_acknowledgement: "recipient_update_acknowledgement"
  }.freeze
  MATCHING_STATUSES = {
    matched: "matched",
    unmatched: "unmatched",
    ambiguous: "ambiguous"
  }.freeze
  MATCHING_METHODS = {
    gmail_thread: "gmail_thread",
    rfc_headers: "rfc_headers",
    invoice_reference: "invoice_reference",
    customer_only: "customer_only",
    none: "none"
  }.freeze
  STATUSES = {
    pending: "pending",
    sent: "sent",
    failed: "failed",
    received: "received"
  }.freeze
  REVIEW_OUTCOMES = {
    manual_match: "manual_match",
    no_match_needed: "no_match_needed"
  }.freeze
  REPLY_SCHEDULING_STATUSES = {
    reserved: "reserved",
    claimed: "claimed",
    enqueued: "enqueued",
    consumed: "consumed",
    exhausted: "exhausted",
    canceled: "canceled"
  }.freeze
  MAXIMUM_REPLY_SCHEDULING_ATTEMPTS = 5
  STALE_REPLY_SCHEDULING_AFTER = 10.minutes
  ReplySchedulingClaim = Data.define(:token, :generation, :attempt, :job_id)

  belongs_to :account, inverse_of: :conversation_messages
  belongs_to :conversation, inverse_of: :conversation_messages
  belongs_to :invoice, optional: true, inverse_of: :conversation_messages
  belongs_to :email_connection, optional: true, inverse_of: :conversation_messages
  belongs_to :reply_to_message,
    class_name: "ConversationMessage",
    optional: true,
    inverse_of: :replies
  belongs_to :actor_user,
    class_name: "User",
    optional: true,
    inverse_of: :authored_conversation_messages
  belongs_to :reviewed_by_user,
    class_name: "User",
    optional: true,
    inverse_of: :reviewed_conversation_messages
  belongs_to :conversation_action_execution,
    optional: true,
    inverse_of: :conversation_message
  has_many :replies,
    class_name: "ConversationMessage",
    foreign_key: :reply_to_message_id,
    dependent: :restrict_with_exception,
    inverse_of: :reply_to_message
  has_one :email_message_receipt,
    dependent: :nullify,
    inverse_of: :conversation_message
  has_one :invoice_reminder,
    dependent: :restrict_with_exception,
    inverse_of: :conversation_message
  has_one :payment_promise,
    foreign_key: :source_message_id,
    dependent: :restrict_with_exception,
    inverse_of: :source_message
  has_one :payment_promise_follow_up,
    class_name: "PaymentPromise",
    foreign_key: :follow_up_message_id,
    dependent: :restrict_with_exception,
    inverse_of: :follow_up_message
  has_many :conversation_events,
    dependent: :nullify,
    inverse_of: :conversation_message
  has_many :conversation_actions,
    foreign_key: :source_message_id,
    dependent: :nullify,
    inverse_of: :source_message
  has_many :collection_holds,
    foreign_key: :source_message_id,
    dependent: :nullify,
    inverse_of: :source_message
  has_many :conversation_escalations,
    foreign_key: :source_message_id,
    dependent: :nullify,
    inverse_of: :source_message

  attribute :review_outcome, :string

  enum :direction, DIRECTIONS, prefix: true, validate: true
  enum :kind, KINDS, prefix: true, validate: true
  enum :status, STATUSES, prefix: true, validate: true
  enum :matching_status, MATCHING_STATUSES, prefix: true, validate: true
  enum :matching_method, MATCHING_METHODS, prefix: true, validate: true
  enum :review_outcome, REVIEW_OUTCOMES, prefix: true, validate: { allow_nil: true }
  enum :reply_scheduling_status,
    REPLY_SCHEDULING_STATUSES,
    prefix: :reply_scheduling,
    validate: { allow_nil: true }

  attribute :to_addresses, default: -> { [] }
  attribute :cc_addresses, default: -> { [] }
  attribute :bcc_addresses, default: -> { [] }
  attribute :reply_to_addresses, default: -> { [] }
  attribute :in_reply_to_message_ids, default: -> { [] }
  attribute :reference_message_ids, default: -> { [] }
  attribute :provider_metadata, default: -> { {} }
  attribute :review_reasons, default: -> { [] }
  attribute :actor_snapshot, default: -> { {} }

  before_validation :assign_outbound_internet_message_id, on: :create
  before_validation :set_internet_message_id_digest
  after_create :touch_conversation

  normalizes :from_address, with: ->(address) { address.to_s.strip.downcase.presence }
  normalizes :provider_account_id,
    :provider_message_id,
    :provider_thread_id,
    :requested_provider_account_id,
    :requested_provider_thread_id,
    :idempotency_key,
    :delivery_job_id,
    with: ->(id) { id.to_s.strip.presence }

  validates :provider_message_id,
    uniqueness: { scope: %i[account_id provider_account_id] },
    allow_nil: true
  validates :sent_at, presence: true, if: :status_sent?
  validates :received_at, presence: true, if: :status_received?
  validate :account_matches_invoice
  validate :account_matches_conversation
  validate :account_matches_email_connection
  validate :invoice_matches_conversation
  validate :invoice_required_for_collection_message
  validate :status_matches_direction
  validate :timestamps_match_status
  validate :successful_messages_have_no_failure_reason
  validate :collection_fields_have_expected_types
  validate :gmail_import_has_email_connection
  validate :email_connection_snapshot_is_complete
  validate :provider_account_matches_email_connection, on: :create
  validate :provider_account_is_immutable, on: :update
  validate :email_connection_generation_is_immutable, on: :update
  validate :user_associations_match_account
  validate :reply_anchor_matches_account
  validate :manual_reply_snapshot_is_complete
  validate :manual_reply_snapshot_is_immutable, on: :update
  validate :review_completion_is_immutable, on: :update
  validate :review_outcome_matches_completion
  validate :delivery_uncertainty_matches_status
  validate :action_reply_scheduling_is_complete
  validate :action_reply_actor_evidence_is_complete

  scope :successful_outbound, -> do
    direction_outbound.where(status: :sent).or(
      direction_outbound.where(delivery_uncertain: true)
    )
  end
  scope :awaiting_review, -> do
    where.not(email_connection_id: nil).where(review_required: true, reviewed_at: nil)
  end
  scope :sent_after, ->(time) do
    where(
      "COALESCE(conversation_messages.sent_at, " \
        "conversation_messages.provider_delivery_started_at) > ?",
      time
    )
  end
  scope :chronological, -> do
    order(
      Arel.sql("COALESCE(received_at, sent_at, created_at) ASC"),
      :id
    )
  end
  scope :trusted_for_matching, -> do
    joins(:conversation).where(
      <<~SQL.squish,
        conversation_messages.matching_status <> :ambiguous
        OR (
          conversation_messages.matching_status = :ambiguous
          AND conversation_messages.review_outcome = :manual_match
          AND conversation_messages.reviewed_at IS NOT NULL
          AND conversation_messages.invoice_id IS NOT NULL
          AND conversations.canonical_conversation_id IS NOT NULL
        )
      SQL
      ambiguous: MATCHING_STATUSES.fetch(:ambiguous),
      manual_match: REVIEW_OUTCOMES.fetch(:manual_match)
    )
  end
  scope :stale_pending_deliveries, ->(before:) do
    pending_messages = direction_outbound.status_pending
    attempted = pending_messages.where(delivery_attempted_at: ...before)
    untracked = pending_messages.where(delivery_attempted_at: nil, created_at: ...before)

    attempted.or(untracked)
  end
  scope :due_action_reply_scheduling, ->(at: Time.current) do
    where.not(conversation_action_execution_id: nil)
      .reply_scheduling_reserved
      .where(
        reply_scheduling_attempts: ...MAXIMUM_REPLY_SCHEDULING_ATTEMPTS
      )
      .where(next_reply_scheduling_at: [ nil, ..at ])
  end
  scope :stale_action_reply_scheduling, ->(before:) do
    where.not(conversation_action_execution_id: nil)
      .reply_scheduling_claimed
      .where(reply_scheduling_claimed_at: ...before)
  end
  scope :stale_enqueued_action_reply_scheduling, ->(before:) do
    where.not(conversation_action_execution_id: nil)
      .reply_scheduling_enqueued
      .where(reply_schedule_consumed_at: nil, reply_scheduled_at: ...before)
  end

  def delivery_owned_by?(job_id)
    normalized_job_id = job_id.to_s.strip.presence

    status_pending? && normalized_job_id.present? && delivery_job_id == normalized_job_id
  end

  def claim_reply_scheduling!(job_id:, at: Time.current)
    token = SecureRandom.uuid
    claim = nil
    with_lock do
      next unless action_reply? && status_pending? &&
        reply_scheduling_reserved?
      next if provider_delivery_claimed?
      next if reply_scheduling_attempts >=
        MAXIMUM_REPLY_SCHEDULING_ATTEMPTS
      next if next_reply_scheduling_at.present? &&
        next_reply_scheduling_at > at

      generation = reply_scheduling_generation + 1
      with_reply_scheduling_change do
        update!(
          reply_scheduling_status: :claimed,
          reply_scheduling_generation: generation,
          reply_scheduling_token: token,
          reply_scheduling_claimed_at: at,
          reply_scheduling_attempts: reply_scheduling_attempts + 1,
          delivery_job_id: job_id,
          last_reply_scheduling_error: nil
        )
      end
      claim = ReplySchedulingClaim.new(
        token:,
        generation:,
        attempt: reply_scheduling_attempts,
        job_id:
      )
    end
    claim
  end

  def record_reply_scheduled!(claim, at: Time.current)
    with_lock do
      verify_reply_scheduling_claim!(claim)
      with_reply_scheduling_change do
        update!(
          reply_scheduling_status: :enqueued,
          reply_scheduling_token: nil,
          reply_scheduling_claimed_at: nil,
          reply_scheduled_at: at,
          last_reply_scheduling_error: nil
        )
      end
    end
    true
  rescue ConversationActionExecution::ClaimLost
    false
  end

  def release_reply_scheduling!(claim, error:, next_attempt_at:)
    exhausted = false
    with_lock do
      verify_reply_scheduling_claim!(claim)
      exhausted = reply_scheduling_attempts >=
        MAXIMUM_REPLY_SCHEDULING_ATTEMPTS
      with_reply_scheduling_change do
        update!(
          reply_scheduling_status: exhausted ? :exhausted : :reserved,
          reply_scheduling_token: nil,
          reply_scheduling_claimed_at: nil,
          next_reply_scheduling_at: exhausted ? nil : next_attempt_at,
          last_reply_scheduling_error: error.to_s.first(2_000)
        )
      end
    end
    exhausted ? :exhausted : :released
  rescue ConversationActionExecution::ClaimLost
    :claim_lost
  end

  def consume_reply_schedule!(generation:, job_id:, at: Time.current)
    consumed = false
    with_lock do
      next unless action_reply? && status_pending?
      next unless reply_scheduling_generation == generation.to_i
      next unless delivery_job_id == job_id.to_s
      next unless reply_scheduling_claimed? || reply_scheduling_enqueued? ||
        (reply_scheduling_consumed? &&
          reply_schedule_consumed_at.present?)

      if !reply_scheduling_consumed?
        with_reply_scheduling_change do
          update!(
            reply_scheduling_status: :consumed,
            reply_scheduling_token: nil,
            reply_scheduling_claimed_at: nil,
            reply_schedule_consumed_at: at
          )
        end
      end
      consumed = true
    end
    consumed
  end

  def recover_stale_reply_scheduling!(before:, at: Time.current)
    recovered = false
    with_lock do
      stale_claim = reply_scheduling_claimed? &&
        reply_scheduling_claimed_at &&
        reply_scheduling_claimed_at < before
      lost_job = reply_scheduling_enqueued? &&
        reply_schedule_consumed_at.nil? &&
        reply_scheduled_at &&
        reply_scheduled_at < before
      next unless stale_claim || lost_job
      next if provider_delivery_claimed?

      with_reply_scheduling_change do
        update!(
          reply_scheduling_status: :reserved,
          reply_scheduling_token: nil,
          reply_scheduling_claimed_at: nil,
          next_reply_scheduling_at: at,
          last_reply_scheduling_error:
            "A stale reply scheduling owner was recovered."
        )
      end
      recovered = true
    end
    recovered
  end

  def action_reply?
    ConversationMessages::ThreadedReply.action_kind?(kind)
  end

  def threaded_reply?
    kind.in?(ConversationMessages::ThreadedReply::KINDS)
  end

  def managed_threaded_reply?
    kind_manual_reply? ||
      (action_reply? && conversation_action_execution_id.present?)
  end

  def provider_delivery_claimed?
    provider_delivery_started_at.present?
  end

  def claim_provider_delivery!(job_id:, started_at: Time.current)
    claimed = false
    with_lock do
      next unless delivery_owned_by?(job_id)
      next if provider_delivery_claimed?

      update!(provider_delivery_started_at: started_at)
      claimed = true
    end
    claimed
  end

  def relinquish_provider_delivery_claim!(
    job_id:,
    connection: nil,
    provider_account_id: nil,
    credential_generation: nil
  )
    released = false
    operation = lambda do
      with_lock do
        next unless delivery_owned_by?(job_id)
        next unless provider_delivery_claimed?
        next if provider_message_id.present?

        attributes = { provider_delivery_started_at: nil }
        if connection
          next unless email_connection_id == connection.id
          next unless self.provider_account_id == provider_account_id.to_s.strip
          next unless email_connection_generation == credential_generation.to_i

          attributes.merge!(
            email_connection: nil,
            email_connection_generation: nil,
            provider_account_id: nil
          )
        end
        with_delivery_mailbox_binding_change { update!(attributes) }
        released = true
      end
    end
    invoice ? invoice.with_lock(&operation) : operation.call
    released
  end

  def refresh_delivery_attempt!(job_id:, mail_message:, attempted_at: Time.current)
    with_owned_pending_delivery(job_id:) do
      apply_internet_message_id!(mail_message)
      attributes = { delivery_attempted_at: attempted_at }
      unless threaded_reply?
        attributes = ConversationMessages::Content
          .from_mail(mail_message)
          .attributes
          .merge(attributes)
      end
      update!(attributes)
    end
  end

  def apply_internet_message_id!(mail_message)
    mail_message.message_id = internet_message_id if internet_message_id.present?
    mail_message
  end

  def provider_account_matches?(connection)
    connection.present? &&
      email_connection_id == connection.id &&
      provider_account_id.present? &&
      provider_account_id == connection.provider_account_id &&
      email_connection_generation == connection.credential_generation
  end

  def bind_delivery_mailbox!(connection:, job_id:)
    return true if provider_account_matches?(connection)

    bound = false
    with_lock do
      next unless delivery_owned_by?(job_id)
      next if email_connection_id.present? ||
        provider_account_id.present? ||
        email_connection_generation.present?

      update!(
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id
      )
      bound = true
    end
    bound
  end

  def release_delivery_mailbox_binding!(
    connection:,
    job_id:,
    provider_account_id:,
    credential_generation:
  )
    released = false
    with_lock do
      next unless delivery_owned_by?(job_id)
      next unless provider_message_id.nil?
      next unless email_connection_id == connection.id
      next unless self.provider_account_id == provider_account_id.to_s.strip
      next unless email_connection_generation == credential_generation.to_i

      with_delivery_mailbox_binding_change do
        update!(
          email_connection: nil,
          email_connection_generation: nil,
          provider_account_id: nil
        )
      end
      released = true
    end
    released
  end

  def mark_delivery_sent!(
    job_id:,
    sent_at: Time.current,
    provider_message_id:,
    provider_thread_id: nil
  )
    with_owned_pending_delivery(job_id:) do
      update!(
        status: :sent,
        sent_at:,
        provider_message_id:,
        provider_thread_id:,
        failure_reason: nil,
        delivery_uncertain: false
      )
    end
  end

  def mark_delivery_failed!(job_id:, failure_reason:, delivery_uncertain: false)
    with_owned_pending_delivery(job_id:) do
      fail_delivery!(failure_reason:, delivery_uncertain:)
    end
  end

  def reconcile_stale_delivery!(before:, failure_reason:, delivery_uncertain: false)
    reconciled = false

    with_lock do
      next unless stale_pending_delivery?(before:)

      fail_delivery!(
        failure_reason:,
        delivery_uncertain: delivery_uncertain || provider_delivery_claimed?
      )
      payment_promise_follow_up&.follow_up_failed!
      reconciled = true
    end

    reconciled
  end

  def occurred_at
    received_at || sent_at || created_at
  end

  def awaiting_review?
    email_connection_id.present? && review_required? && reviewed_at.nil?
  end

  def trusted_matching_anchor?
    !matching_status_ambiguous? ||
      (
        review_outcome_manual_match? &&
        reviewed_at.present? &&
        invoice_id.present? &&
        conversation.canonical_conversation_id.present?
      )
  end

  def correct_review_to_manual_match!(actor_user:, at: Time.current)
    return false if review_outcome_manual_match?
    unless review_outcome_no_match_needed? && reviewed_at.present? &&
        actor_user.account_id == account_id
      raise ActiveRecord::RecordInvalid, self
    end

    @review_outcome_correction = true
    update!(review_outcome: :manual_match)
    ConversationEvent.record_once!(
      conversation:,
      conversation_message: self,
      kind: :conversation_message_review_corrected,
      actor_kind: :user,
      actor_user:,
      metadata: {
        "previous_outcome" => "no_match_needed",
        "outcome" => "manual_match",
        "matching_status" => matching_status,
        "matching_method" => matching_method,
        "review_reasons" => review_reasons
      },
      created_at: at
    )
    true
  ensure
    @review_outcome_correction = false
  end

  def reconcile_imported_manual_reply!(
    receipt:,
    parsed_message:,
    provider_account_id:
  )
    return false unless kind_manual_reply?

    reconcile_imported_app_delivery!(
      receipt:,
      parsed_message:,
      provider_account_id:
    )
  end

  def reconcile_imported_app_delivery!(
    receipt:,
    parsed_message:,
    provider_account_id:
  )
    reconciled = false
    with_lock do
      next unless direction_outbound? && app_created_delivery_kind?
      next unless delivery_provider_account_id == provider_account_id.to_s.strip
      next unless internet_message_id == parsed_message.internet_message_id

      previously_uncertain = delivery_uncertain? || provider_delivery_claimed?
      with_delivery_mailbox_binding_change do
        update!(
          email_connection: receipt.email_connection,
          email_connection_generation: receipt.email_connection_generation,
          provider_account_id:,
          provider_message_id: parsed_message.provider_message_id,
          provider_thread_id: parsed_message.provider_thread_id,
          status: :sent,
          sent_at: parsed_message.internal_date,
          failure_reason: nil,
          delivery_uncertain: false
        )
      end
      ConversationEvent.record_once!(
        conversation:,
        conversation_message: self,
        kind: :conversation_message_imported,
        actor_kind: :system,
        metadata: {
          "reconciled_app_delivery" => true,
          "delivery_kind" => kind,
          "previously_uncertain" => previously_uncertain
        }
      ) unless kind_manual_reply?
      reconciled = true
    end
    reconciled
  end

  private
    def with_owned_pending_delivery(job_id:)
      updated = false

      with_lock do
        next unless delivery_owned_by?(job_id)

        yield
        updated = true
      end

      updated
    end

    def app_created_delivery_kind?
      kind.in?(
        %w[
          manual_reply
          manual_reminder
          scheduled_reminder
          promise_follow_up
          due_date_answer
          payment_status_answer
          outstanding_amount_answer
          invoice_resend
          payment_promise_acknowledgement
          dispute_acknowledgement
          recipient_update_acknowledgement
        ]
      )
    end

    def delivery_provider_account_id
      if threaded_reply?
        requested_provider_account_id
      else
        provider_account_id
      end
    end

    def stale_pending_delivery?(before:)
      return false unless direction_outbound? && status_pending?

      (delivery_attempted_at || created_at) < before
    end

    def fail_delivery!(failure_reason:, delivery_uncertain: false)
      update!(
        status: :failed,
        sent_at: nil,
        provider_message_id: nil,
        provider_thread_id: nil,
        failure_reason:,
        delivery_uncertain:
      )
    end

    def account_matches_invoice
      return if account.blank? || invoice.blank? || account == invoice.account

      errors.add(:account, "must match invoice account")
    end

    def account_matches_conversation
      return if account.blank? || conversation.blank? || account == conversation.account

      errors.add(:account, "must match conversation account")
    end

    def account_matches_email_connection
      return if account.blank? || email_connection.blank? || account == email_connection.account

      errors.add(:email_connection, "must belong to the message account")
    end

    def invoice_matches_conversation
      return if conversation.blank?

      if conversation.invoice.present?
        return if invoice == conversation.invoice

        errors.add(:invoice, "must match conversation invoice")
      elsif conversation.canonical_conversation&.invoice.present?
        return if invoice == conversation.canonical_conversation.invoice

        errors.add(:invoice, "must match the canonical conversation invoice")
      elsif invoice.present?
        errors.add(:invoice, "must be blank for an unmatched conversation")
      end
    end

    def invoice_required_for_collection_message
      return if invoice.present?
      return if unmatched_customer_email? || unmatched_manual_email?

      errors.add(:invoice, "is required unless this is a received customer email in an unmatched conversation")
    end

    def unmatched_manual_email?
      conversation&.invoice.blank? &&
        direction_outbound? &&
        status_sent? &&
        kind_manual_email? &&
        email_connection.present?
    end

    def unmatched_customer_email?
      conversation&.invoice.blank? &&
        direction_inbound? &&
        status_received? &&
        kind_customer_email?
    end

    def status_matches_direction
      return if direction.blank? || status.blank?

      if direction_inbound? && !status_received?
        errors.add(:status, "must be received for inbound messages")
      elsif direction_outbound? && status_received?
        errors.add(:status, "must be received only for inbound messages")
      end
    end

    def timestamps_match_status
      if status_sent?
        errors.add(:received_at, "must be blank for sent messages") if received_at.present?
      elsif status_received?
        errors.add(:sent_at, "must be blank for received messages") if sent_at.present?
      else
        errors.add(:sent_at, "must be blank until the message is sent") if sent_at.present?
        errors.add(:received_at, "must be blank unless the message was received") if received_at.present?
      end
    end

    def successful_messages_have_no_failure_reason
      return unless (status_sent? || status_received?) && failure_reason.present?

      errors.add(:failure_reason, "must be blank for successful messages")
    end

    def collection_fields_have_expected_types
      %i[
        to_addresses
        cc_addresses
        bcc_addresses
        reply_to_addresses
        in_reply_to_message_ids
        reference_message_ids
        review_reasons
      ].each do |attribute_name|
        errors.add(attribute_name, "must be an array") unless public_send(attribute_name).is_a?(Array)
      end
      errors.add(:provider_metadata, "must be an object") unless provider_metadata.is_a?(Hash)
    end

    def gmail_import_has_email_connection
      return unless kind_customer_email? || kind_manual_email?
      return unless provider_message_id.present?

      errors.add(:email_connection, "is required for Gmail-imported email") if email_connection.blank?
      errors.add(:provider_account_id, "is required for Gmail-imported email") if provider_account_id.blank?
      if email_connection_generation.nil?
        errors.add(:email_connection_generation, "is required for Gmail-imported email")
      end
    end

    def email_connection_snapshot_is_complete
      return if email_connection.blank?

      errors.add(:provider_account_id, "is required with an email connection") if provider_account_id.blank?
      if email_connection_generation.nil?
        errors.add(:email_connection_generation, "is required with an email connection")
      end
    end

    def provider_account_matches_email_connection
      return if email_connection.blank?

      if provider_account_id.present? &&
          provider_account_id != email_connection.provider_account_id
        errors.add(:provider_account_id, "must match the email connection identity")
      end

      if email_connection_generation.present? &&
          email_connection_generation != email_connection.credential_generation
        errors.add(
          :email_connection_generation,
          "must match the email connection credential generation"
        )
      end
    end

    def provider_account_is_immutable
      return unless will_save_change_to_provider_account_id?
      return if @delivery_mailbox_binding_change_allowed
      return if initial_pending_provider_account_binding?

      errors.add(:provider_account_id, "cannot be changed")
    end

    def email_connection_generation_is_immutable
      return unless will_save_change_to_email_connection_generation?
      return if @delivery_mailbox_binding_change_allowed
      return if initial_pending_email_connection_generation_binding?

      errors.add(:email_connection_generation, "cannot be changed")
    end

    def user_associations_match_account
      if actor_user.present? && account.present? && actor_user.account != account
        errors.add(:actor_user, "must belong to the message account")
      end
      if reviewed_by_user.present? && account.present? && reviewed_by_user.account != account
        errors.add(:reviewed_by_user, "must belong to the message account")
      end
    end

    def reply_anchor_matches_account
      return if reply_to_message.blank? || account.blank?
      return if reply_to_message.account == account

      errors.add(:reply_to_message, "must belong to the message account")
    end

    def manual_reply_snapshot_is_complete
      return unless managed_threaded_reply?

      {
        reply_to_message:,
        idempotency_key:,
        requested_provider_account_id:,
        requested_provider_thread_id:,
        internet_message_id:
      }.each do |attribute_name, value|
        errors.add(attribute_name, "must be present for a threaded reply") if value.blank?
      end
      errors.add(:body, "must be present for a threaded reply") if body.blank?
      errors.add(:to_addresses, "must contain exactly one recipient") unless to_addresses.one?
      if action_reply? && conversation_action_execution.blank?
        errors.add(
          :conversation_action_execution,
          "must be present for an action reply"
        )
      elsif kind_manual_reply? && conversation_action_execution.present?
        errors.add(
          :conversation_action_execution,
          "must be blank for a manual reply"
        )
      end
      errors.add(:bcc_addresses, "must be empty for a threaded reply") if
        bcc_addresses.any?
      if kind_manual_reply? && delivery_job_id.blank?
        errors.add(
          :delivery_job_id,
          "must be present for a manual reply"
        )
      end
      if kind_manual_reply? && actor_user.blank?
        errors.add(:actor_user, "must be present for a manual reply")
      end
    end

    def manual_reply_snapshot_is_immutable
      return unless managed_threaded_reply?

      %i[
        account_id
        conversation_id
        invoice_id
        reply_to_message_id
        actor_user_id
        actor_snapshot
        conversation_action_execution_id
        requested_provider_account_id
        requested_provider_thread_id
        idempotency_key
        delivery_job_id
        internet_message_id
        from_address
        to_addresses
        cc_addresses
        bcc_addresses
        subject
        body
        in_reply_to_message_ids
        reference_message_ids
      ].each do |attribute_name|
        if will_save_change_to_attribute?(attribute_name)
          next if attribute_name == :delivery_job_id &&
            @reply_scheduling_change_allowed

          errors.add(attribute_name, "cannot be changed after the reply is queued")
        end
      end
    end

    def action_reply_scheduling_is_complete
      if action_reply? && conversation_action_execution_id.present?
        errors.add(:reply_scheduling_status, "must be present") if
          reply_scheduling_status.blank?
      elsif reply_scheduling_status.present?
        errors.add(
          :reply_scheduling_status,
          "is only available for action replies"
        )
      end
    end

    def action_reply_actor_evidence_is_complete
      return unless action_reply? && conversation_action_execution_id.present?
      return if actor_user.present? || actor_snapshot.to_h["id"].present?

      errors.add(
        :actor_snapshot,
        "must preserve the approving user identity"
      )
    end

    def with_reply_scheduling_change
      previous = @reply_scheduling_change_allowed
      @reply_scheduling_change_allowed = true
      yield
    ensure
      @reply_scheduling_change_allowed = previous
    end

    def verify_reply_scheduling_claim!(claim)
      reload
      valid = claim &&
        reply_scheduling_claimed? &&
        reply_scheduling_token == claim.token &&
        reply_scheduling_generation == claim.generation &&
        delivery_job_id == claim.job_id
      return if valid

      raise ConversationActionExecution::ClaimLost,
        "Reply scheduling ownership changed."
    end

    def review_completion_is_immutable
      return if reviewed_at_was.nil?

      if will_save_change_to_reviewed_at? || will_save_change_to_reviewed_by_user_id?
        errors.add(:reviewed_at, "cannot be changed after review")
      end
      if will_save_change_to_matching_status? ||
          will_save_change_to_matching_method? ||
          will_save_change_to_review_reasons?
        errors.add(:matching_status, "evidence cannot be changed after review")
      end
      if will_save_change_to_review_outcome? && !@review_outcome_correction
        errors.add(:review_outcome, "cannot be changed after review")
      end
    end

    def review_outcome_matches_completion
      if review_outcome.present?
        unless review_required? && reviewed_at.present? && reviewed_by_user.present?
          errors.add(:review_outcome, "requires a completed human review")
        end
      elsif review_required? && reviewed_at.present?
        errors.add(:review_outcome, "must identify how review was completed")
      end
    end

    def delivery_uncertainty_matches_status
      return unless delivery_uncertain?
      return if status_failed?

      errors.add(:delivery_uncertain, "is only valid for a failed delivery")
    end

    def initial_pending_provider_account_binding?
      provider_account_id_was.nil? &&
        provider_account_id.present? &&
        email_connection.present? &&
        provider_account_id == email_connection.provider_account_id &&
        email_connection_generation == email_connection.credential_generation &&
        app_reserved_pending_delivery? &&
        provider_message_id.nil?
    end

    def initial_pending_email_connection_generation_binding?
      email_connection_generation_was.nil? &&
        email_connection_generation.present? &&
        email_connection.present? &&
        provider_account_id == email_connection.provider_account_id &&
        email_connection_generation == email_connection.credential_generation &&
        app_reserved_pending_delivery? &&
        provider_message_id.nil?
    end

    def with_delivery_mailbox_binding_change
      @delivery_mailbox_binding_change_allowed = true
      yield
    ensure
      @delivery_mailbox_binding_change_allowed = false
    end

    def assign_outbound_internet_message_id
      return unless app_reserved_pending_delivery?

      self.internet_message_id ||= "<#{SecureRandom.uuid}@paymentreminder.local>"
    end

    def app_reserved_pending_delivery?
      direction_outbound? &&
        status_pending? &&
        (
          delivery_job_id.present? ||
          (
            action_reply? &&
            conversation_action_execution_id.present? &&
            reply_scheduling_status.present?
          )
        )
    end

    def set_internet_message_id_digest
      self.internet_message_id_digest = if internet_message_id.present?
        Digest::SHA256.hexdigest(internet_message_id)
      end
    end

    def touch_conversation
      conversation.touch
    end
end

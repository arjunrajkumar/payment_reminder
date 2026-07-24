class ConversationActionExecution < ApplicationRecord
  MAXIMUM_ATTEMPTS = 5
  MAXIMUM_SCHEDULING_ATTEMPTS = 5
  STALE_CLAIM_AFTER = 30.minutes
  STALE_SCHEDULING_CLAIM_AFTER = 10.minutes

  Claim = Data.define(:token, :generation, :phase, :attempt)
  SchedulingClaim = Data.define(:token, :generation, :attempt)

  class ClaimLost < ConversationActions::Error; end
  class InvalidTransition < ConversationActions::Error; end

  STATUSES = {
    pending: "pending",
    running: "running",
    awaiting_delivery: "awaiting_delivery",
    succeeded: "succeeded",
    failed: "failed",
    uncertain: "uncertain",
    canceled: "canceled"
  }.freeze
  PHASES = {
    effect: "effect",
    reply_reservation: "reply_reservation",
    delivery: "delivery",
    finalized: "finalized"
  }.freeze
  SCHEDULING_STATUSES = {
    reserved: "reserved",
    claimed: "claimed",
    enqueued: "enqueued",
    consumed: "consumed",
    exhausted: "exhausted",
    canceled: "canceled"
  }.freeze
  FINALIZATION_STATUSES = {
    not_required: "not_required",
    pending: "pending",
    completed: "completed"
  }.freeze
  TERMINAL_STATUSES = %w[succeeded failed uncertain canceled].freeze

  belongs_to :account, inverse_of: :conversation_action_executions
  belongs_to :conversation_action, inverse_of: :execution
  belongs_to :conversation_action_revision
  belongs_to :approved_by_user,
    class_name: "User",
    optional: true,
    inverse_of: :approved_conversation_action_executions
  belongs_to :payment_promise, optional: true
  belongs_to :customer_email_address, optional: true
  belongs_to :collection_hold, optional: true
  belongs_to :effect_escalation,
    class_name: "ConversationEscalation",
    optional: true
  belongs_to :delivery_escalation,
    class_name: "ConversationEscalation",
    optional: true
  has_one :conversation_message,
    dependent: :nullify,
    inverse_of: :conversation_action_execution

  enum :status, STATUSES, prefix: true, validate: true
  enum :phase, PHASES, prefix: true, validate: true
  enum :scheduling_status,
    SCHEDULING_STATUSES,
    prefix: :scheduling,
    validate: true
  enum :finalization_status,
    FINALIZATION_STATUSES,
    prefix: :finalization,
    validate: true

  attribute :approver_snapshot, default: -> { {} }
  attribute :result_metadata, default: -> { {} }
  attribute :reply_snapshot, default: -> { {} }

  validates :conversation_action_id, uniqueness: true
  validates :conversation_action_revision_id, uniqueness: true
  validates :attempts,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: MAXIMUM_ATTEMPTS
    }
  validates :claim_generation,
    :scheduling_generation,
    :attention_version,
    :acknowledged_attention_version,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :scheduling_attempts,
    numericality: {
      only_integer: true,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: MAXIMUM_SCHEDULING_ATTEMPTS
    }
  validates :approver_snapshot, presence: true
  validates :failure_reason,
    :last_scheduling_error,
    length: { maximum: 2_000 },
    allow_nil: true
  validate :records_match_approval
  validate :attention_versions_are_ordered

  before_validation :initialize_scheduling, on: :create
  before_update :prevent_unaudited_update
  after_create_commit :enqueue_execution
  before_destroy :prevent_independent_deletion

  scope :due_for_scheduling, ->(at: Time.current) do
    status_pending
      .scheduling_reserved
      .where(scheduling_attempts: ...MAXIMUM_SCHEDULING_ATTEMPTS)
      .where(next_scheduling_at: [ nil, ..at ])
  end
  scope :stale_scheduling_claims, ->(before:) do
    scheduling_claimed.where(scheduling_claimed_at: ...before)
  end
  scope :stale_enqueued_scheduling, ->(before:) do
    scheduling_enqueued
      .where(schedule_consumed_at: nil, scheduled_at: ...before)
  end
  scope :due_for_phase, ->(at: Time.current) do
    status_pending
      .where(attempts: ...MAXIMUM_ATTEMPTS)
      .where(next_retry_at: [ nil, ..at ])
  end
  scope :stale_running, ->(before:) do
    status_running.where(claimed_at: ...before)
  end
  scope :needing_delivery_finalization, -> do
    finalization_pending
      .where(status: %i[awaiting_delivery failed uncertain])
  end

  def claim_phase!(expected_phase: phase, at: Time.current)
    token = SecureRandom.uuid
    claimed = nil
    with_lock do
      next unless status_pending? && phase == expected_phase.to_s
      next if attempts >= MAXIMUM_ATTEMPTS
      next if next_retry_at.present? && next_retry_at > at

      next_generation = claim_generation + 1
      lifecycle_update!(
        status: :running,
        attempts: attempts + 1,
        claim_generation: next_generation,
        claim_token: token,
        claimed_at: at,
        next_retry_at: nil,
        failure_category: nil,
        failure_reason: nil
      )
      claimed = Claim.new(
        token:,
        generation: next_generation,
        phase:,
        attempt: attempts
      )
    end
    claimed
  end

  def verify_claim!(claim, expected_phase: claim&.phase)
    reload
    valid = claim &&
      status_running? &&
      phase == expected_phase.to_s &&
      claim_token == claim.token &&
      claim_generation == claim.generation
    return true if valid

    raise ClaimLost, "Execution ownership changed; obsolete work was ignored."
  end

  def transition_from_claim!(claim, to_status:, to_phase:, **attributes)
    verify_claim!(claim)
    validate_transition!(from: status, to: to_status, authoritative_sent: false)
    lifecycle_update!(
      **attributes,
      status: to_status,
      phase: to_phase,
      claim_token: nil,
      claimed_at: nil
    )
  end

  def release_claim!(
    claim,
    next_retry_at:,
    failure_category:,
    failure_reason:
  )
    with_lock do
      verify_claim!(claim)
      transition_from_claim!(
        claim,
        to_status: :pending,
        to_phase: phase,
        next_retry_at:,
        failure_category:,
        failure_reason:,
        scheduling_status: :reserved,
        scheduling_attempts: 0,
        scheduling_token: nil,
        scheduling_claimed_at: nil,
        next_scheduling_at: next_retry_at,
        scheduled_at: nil,
        schedule_consumed_at: nil
      )
    end
    true
  rescue ClaimLost
    false
  end

  def fail_pending!(at:, **attributes)
    changed = false
    with_lock do
      next unless status_pending?

      validate_transition!(
        from: status,
        to: :failed,
        authoritative_sent: false
      )
      lifecycle_update!(
        **attributes,
        status: :failed,
        phase: :finalized,
        finished_at: at,
        claim_token: nil,
        claimed_at: nil,
        scheduling_status: :exhausted,
        scheduling_token: nil,
        scheduling_claimed_at: nil
      )
      changed = true
    end
    changed
  end

  def finalize_delivery!(
    outcome:,
    message:,
    at:,
    delivery_escalation: nil,
    authoritative_sent: false
  )
    reload
    target_status = {
      succeeded: :succeeded,
      failed: :failed,
      uncertain: :uncertain
    }.fetch(outcome.to_sym)
    if status == target_status.to_s && finalization_completed?
      return false
    end
    validate_transition!(
      from: status,
      to: target_status,
      authoritative_sent:
    )

    attention = !!(
      target_status != :succeeded ||
        effect_escalation&.status_open? ||
        delivery_escalation&.status_open?
    )
    metadata = result_metadata.merge(
      "conversation_message_id" => message.id,
      "provider_message_id" => message.provider_message_id
    ).compact
    attributes = {
      status: target_status,
      phase: :finalized,
      finished_at: at,
      finalization_status: :completed,
      delivery_finalized_at: at,
      attention_required: attention,
      attention_version: attention && !attention_required? ?
        attention_version + 1 :
        attention_version,
      delivery_escalation:,
      result_metadata: metadata
    }
    case target_status
    when :succeeded
      attributes.merge!(
        failure_category: nil,
        failure_reason: nil,
        result_code: authoritative_sent ?
          "gmail_sent_reconciled" :
          "reply_delivered"
      )
    when :failed
      attributes.merge!(
        failure_category: "delivery_failed",
        failure_reason: "Gmail could not send this reply.",
        result_code: "reply_delivery_failed"
      )
    when :uncertain
      attributes.merge!(
        failure_category: "delivery_unconfirmed",
        failure_reason:
          ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON,
        result_code: "reply_delivery_unconfirmed"
      )
    end
    lifecycle_update!(attributes)
    true
  end

  def claim_scheduling!(at: Time.current)
    token = SecureRandom.uuid
    claim = nil
    with_lock do
      next unless status_pending? && scheduling_reserved?
      next if scheduling_attempts >= MAXIMUM_SCHEDULING_ATTEMPTS
      next if next_scheduling_at.present? && next_scheduling_at > at

      generation = scheduling_generation + 1
      lifecycle_update!(
        scheduling_status: :claimed,
        scheduling_generation: generation,
        scheduling_token: token,
        scheduling_claimed_at: at,
        scheduling_attempts: scheduling_attempts + 1,
        last_scheduling_error: nil
      )
      claim = SchedulingClaim.new(
        token:,
        generation:,
        attempt: scheduling_attempts
      )
    end
    claim
  end

  def record_scheduled!(claim, at: Time.current)
    with_lock do
      verify_scheduling_claim!(claim)
      lifecycle_update!(
        scheduling_status: :enqueued,
        scheduling_token: nil,
        scheduling_claimed_at: nil,
        scheduled_at: at,
        last_scheduling_error: nil
      )
    end
    true
  rescue ClaimLost
    false
  end

  def release_scheduling!(claim, error:, next_attempt_at:)
    exhausted = false
    with_lock do
      verify_scheduling_claim!(claim)
      exhausted = scheduling_attempts >= MAXIMUM_SCHEDULING_ATTEMPTS
      lifecycle_update!(
        scheduling_status: exhausted ? :exhausted : :reserved,
        scheduling_token: nil,
        scheduling_claimed_at: nil,
        next_scheduling_at: exhausted ? nil : next_attempt_at,
        last_scheduling_error: error.to_s.first(2_000)
      )
    end
    exhausted ? :exhausted : :released
  rescue ClaimLost
    :claim_lost
  end

  def consume_schedule!(generation:, at: Time.current)
    consumed = false
    with_lock do
      next unless status_pending?
      next unless scheduling_generation == generation.to_i
      next unless scheduling_claimed? || scheduling_enqueued?

      lifecycle_update!(
        scheduling_status: :consumed,
        scheduling_token: nil,
        scheduling_claimed_at: nil,
        schedule_consumed_at: at
      )
      consumed = true
    end
    consumed
  end

  def recover_stale_scheduling_claim!(before:, at: Time.current)
    recovered = false
    with_lock do
      stale_claim = scheduling_claimed? &&
        scheduling_claimed_at &&
        scheduling_claimed_at < before
      lost_job = scheduling_enqueued? &&
        schedule_consumed_at.nil? &&
        scheduled_at &&
        scheduled_at < before
      next unless stale_claim || lost_job

      lifecycle_update!(
        scheduling_status: :reserved,
        scheduling_token: nil,
        scheduling_claimed_at: nil,
        next_scheduling_at: at,
        last_scheduling_error: "A stale scheduling owner was recovered."
      )
      recovered = true
    end
    recovered
  end

  def recover_stale_execution_claim!(before:, at: Time.current)
    recovered = false
    with_lock do
      next unless status_running? && claimed_at && claimed_at < before

      lifecycle_update!(
        status: :pending,
        claim_token: nil,
        claimed_at: nil,
        next_retry_at: at,
        scheduling_status: :reserved,
        scheduling_attempts: 0,
        scheduling_token: nil,
        scheduling_claimed_at: nil,
        next_scheduling_at: at,
        scheduled_at: nil,
        schedule_consumed_at: nil,
        failure_category: "stale_claim_recovered",
        failure_reason: nil
      )
      recovered = true
    end
    recovered
  end

  def mark_attention!(attributes = {})
    with_lock do
      lifecycle_update!(
        **attributes,
        attention_required: true,
        attention_version: attention_version + 1
      )
    end
  end

  def acknowledge_attention!(expected_version:)
    acknowledged = false
    with_lock do
      next unless attention_required?
      next unless attention_version == expected_version.to_i
      next if effect_escalation&.status_open? ||
        delivery_escalation&.status_open?

      lifecycle_update!(
        attention_required: false,
        acknowledged_attention_version: attention_version
      )
      acknowledged = true
    end
    acknowledged
  end

  def clear_resolved_attention!
    cleared = false
    with_lock do
      next unless attention_required?
      next if effect_escalation&.status_open? ||
        delivery_escalation&.status_open?

      lifecycle_update!(
        attention_required: false,
        acknowledged_attention_version: attention_version
      )
      cleared = true
    end
    cleared
  end

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def conversation_escalation
    effect_escalation || delivery_escalation
  end

  def destroy_for_parent!
    @destroying_for_parent = true
    destroy!
  ensure
    @destroying_for_parent = false
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord,
      "Action executions are retained as historical evidence"
  end

  private
    def initialize_scheduling
      self.next_scheduling_at ||= Time.current
    end

    def enqueue_execution
      ConversationActions::ExecutionRequest.enqueue(self)
    end

    def verify_scheduling_claim!(claim)
      reload
      valid = claim &&
        scheduling_claimed? &&
        scheduling_token == claim.token &&
        scheduling_generation == claim.generation
      return true if valid

      raise ClaimLost, "Execution scheduling ownership changed."
    end

    def lifecycle_update!(attributes)
      previous = @lifecycle_update_allowed
      @lifecycle_update_allowed = true
      update!(attributes)
    ensure
      @lifecycle_update_allowed = previous
    end

    def prevent_unaudited_update
      changed = changes_to_save.keys.to_set - %w[updated_at lock_version]
      return if changed.empty? || @lifecycle_update_allowed

      raise ActiveRecord::ReadOnlyRecord,
        "Action execution lifecycle and evidence are immutable"
    end

    def validate_transition!(from:, to:, authoritative_sent:)
      from = from.to_s
      to = to.to_s
      allowed = case from
      when "pending"
        %w[running failed canceled]
      when "running"
        %w[pending awaiting_delivery succeeded failed canceled]
      when "awaiting_delivery"
        %w[succeeded failed uncertain]
      when "failed", "uncertain"
        authoritative_sent ? %w[succeeded] : []
      else
        []
      end
      return if to == from || to.in?(allowed)

      raise InvalidTransition, "Invalid execution transition #{from} -> #{to}."
    end

    def records_match_approval
      return if account.blank? || conversation_action.blank? ||
        conversation_action_revision.blank?

      errors.add(:conversation_action, "must belong to the execution account") unless
        conversation_action.account_id == account_id
      errors.add(:conversation_action_revision, "must be the approved revision") unless
        conversation_action.status_approved? &&
          conversation_action.decided_revision_id == conversation_action_revision_id
      if approved_by_user.present? && approved_by_user.account_id != account_id
        errors.add(:approved_by_user, "must belong to the execution account")
      end
    end

    def attention_versions_are_ordered
      return if acknowledged_attention_version.to_i <= attention_version.to_i

      errors.add(
        :acknowledged_attention_version,
        "cannot exceed the current attention version"
      )
    end

    def prevent_independent_deletion
      return if destroyed_by_association || @destroying_for_parent

      raise ActiveRecord::DeleteRestrictionError,
        "Action executions are retained as historical evidence"
    end
end

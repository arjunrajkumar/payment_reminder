class CollectionHold < ApplicationRecord
  attr_accessor :validated_work_unit_message_ids

  REASONS = {
    manual: "manual",
    dispute: "dispute",
    other: "other"
  }.freeze
  STATUSES = {
    active: "active",
    released: "released"
  }.freeze
  PLACED_BY_KINDS = ConversationAction::ORIGIN_KINDS

  belongs_to :account, inverse_of: :collection_holds
  belongs_to :invoice, inverse_of: :collection_holds
  belongs_to :customer, optional: true
  belongs_to :conversation, inverse_of: :collection_holds
  belongs_to :source_message,
    class_name: "ConversationMessage",
    optional: true,
    inverse_of: :collection_holds
  belongs_to :conversation_action,
    optional: true,
    inverse_of: :collection_holds
  belongs_to :placed_by_user,
    class_name: "User",
    optional: true,
    inverse_of: :placed_collection_holds
  belongs_to :released_by_user,
    class_name: "User",
    optional: true,
    inverse_of: :released_collection_holds
  has_many :conversation_escalations,
    dependent: :nullify,
    inverse_of: :collection_hold

  enum :reason, REASONS, prefix: true, validate: true
  enum :status, STATUSES, prefix: true, validate: true
  enum :placed_by_kind, PLACED_BY_KINDS, prefix: true, validate: true

  normalizes :idempotency_key,
    :release_idempotency_key,
    with: ->(value) { value.to_s.strip.presence }

  validates :idempotency_key, presence: true, uniqueness: { scope: :account_id }
  validates :placed_at, presence: true
  validates :customer_snapshot, presence: true
  validates :note, :release_note, length: { maximum: 4_000 }, allow_nil: true
  validate :records_match_canonical_invoice_work_unit
  validate :placement_actor_matches_kind
  validate :release_state_matches_status

  before_destroy :prevent_independent_deletion
  before_validation :prevent_unaudited_update, on: :update
  before_update :prevent_unaudited_update

  def release!(
    actor_user:,
    release_note: nil,
    idempotency_key:,
    snapshot_token:,
    at: Time.current
  )
    key = idempotency_key.to_s.strip
    raise ActiveRecord::RecordNotFound unless actor_user&.account_id == account_id
    raise ArgumentError, "Idempotency key is required." if key.blank?
    payload = CollectionHolds::HoldSnapshot.verify!(
      token: snapshot_token,
      hold: self,
      idempotency_key: key
    )
    changed = false

    invoice.with_lock do
      reload
      if status_released?
        exact = released_by_user_id == actor_user.id &&
          self.release_note == release_note.to_s.strip.presence &&
          release_idempotency_key == key
        unless exact
          raise CollectionHolds::InvalidTransition,
            "This collection hold has already been released."
        end
        next
      end
      CollectionHolds::HoldSnapshot.ensure_current!(payload:, hold: self)
      with_audited_release do
        update!(
          status: :released,
          released_by_user: actor_user,
          released_at: at,
          release_note: release_note.to_s.strip.presence,
          release_idempotency_key: key
        )
      end
      ConversationEvent.record!(
        conversation:,
        kind: :collection_hold_released,
        actor_kind: :user,
        actor_user:,
        metadata: {
          "collection_hold_id" => id,
          "invoice_id" => invoice_id,
          "reason" => reason,
          "from_status" => "active",
          "to_status" => "released"
        },
        created_at: at
      )
      changed = true
    end
    self
  end

  def destroy_for_parent!
    @destroying_for_parent = true
    destroy!
  ensure
    @destroying_for_parent = false
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord,
      "Collection holds are retained as historical evidence"
  end

  private :destroy_for_parent!

  private
    def with_audited_release
      previous = @audited_release
      @audited_release = true
      yield
    ensure
      @audited_release = previous
    end

    def prevent_unaudited_update
      changed = changes_to_save.keys.to_set - %w[updated_at lock_version]
      allowed = %w[
        status released_by_user_id released_at release_note
        release_idempotency_key
      ].to_set
      return if @audited_release && changed.subset?(allowed)
      return if changed.empty?

      raise ActiveRecord::ReadOnlyRecord,
        "Collection hold provenance and lifecycle are immutable"
    end

    def records_match_canonical_invoice_work_unit
      return if account.blank? || invoice.blank? || conversation.blank?

      errors.add(:invoice, "must belong to the hold account") unless invoice.account == account
      if customer.present?
        errors.add(:customer, "must belong to the hold account") unless customer.account == account
      elsif new_record?
        errors.add(:customer, "must be present when placing a hold")
      end
      if new_record? && customer.present? && customer != invoice.customer
        errors.add(:customer, "must be the invoice customer snapshot")
      end
      errors.add(:conversation, "must be the canonical invoice conversation") unless
        conversation.account == account &&
          conversation.canonical_conversation_id.nil? &&
          conversation.invoice == invoice
      if source_message.present? && !(
        source_message.account == account &&
          (
            validated_work_unit_message_ids&.include?(source_message.id) ||
            Conversations::ReviewWorkUnit.includes_message?(
              conversation:,
              message: source_message
            )
          )
      )
        errors.add(:source_message, "must belong to the conversation work unit")
      end
      if conversation_action.present? && !(
        conversation_action.account_id == account.id &&
          conversation_action.conversation_id == conversation.id
      )
        errors.add(:conversation_action, "must belong to the conversation work unit")
      end
    end

    def placement_actor_matches_kind
      if placed_by_kind_user?
        errors.add(:placed_by_user, "must be present") if placed_by_user.blank?
      elsif placed_by_user.present?
        errors.add(:placed_by_user, "must be blank for system or AI holds")
      end
      if placed_by_user.present? && account.present? &&
          placed_by_user.account != account
        errors.add(:placed_by_user, "must belong to the hold account")
      end
    end

    def release_state_matches_status
      fields = [ released_by_user, released_at, release_idempotency_key ]
      if status_active?
        if fields.any?(&:present?) || release_note.present?
          errors.add(:base, "active holds cannot have release fields")
        end
      elsif fields.any?(&:blank?)
        errors.add(:base, "released holds require an actor, time, and idempotency key")
      end
      if released_by_user.present? && account.present? &&
          released_by_user.account != account
        errors.add(:released_by_user, "must belong to the hold account")
      end
    end

    def prevent_independent_deletion
      return if destroyed_by_association || @destroying_for_parent

      raise ActiveRecord::DeleteRestrictionError,
        "Collection holds are retained as historical evidence"
    end
end

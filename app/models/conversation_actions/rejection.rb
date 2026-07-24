class ConversationActions::Rejection
  def self.call(
    action:,
    revision:,
    actor_user:,
    rationale:,
    idempotency_key:,
    snapshot_token:,
    at: Time.current
  )
    if rationale.to_s.strip.blank?
      action.errors.add(:decision_note, "is required when rejecting an action")
      raise ActiveRecord::RecordInvalid, action
    end

    ConversationActions::Decision.new(
      action:,
      revision:,
      actor_user:,
      note: rationale,
      idempotency_key:,
      snapshot_token:,
      status: :rejected,
      event_kind: :conversation_action_rejected,
      at:
    ).call
  end
end

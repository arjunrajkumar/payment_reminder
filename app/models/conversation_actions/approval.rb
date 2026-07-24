class ConversationActions::Approval
  def self.call(
    action:,
    revision:,
    actor_user:,
    note: nil,
    idempotency_key:,
    snapshot_token:,
    at: Time.current
  )
    ConversationActions::Decision.new(
      action:,
      revision:,
      actor_user:,
      note:,
      idempotency_key:,
      snapshot_token:,
      status: :approved,
      event_kind: :conversation_action_approved,
      at:
    ).call
  end
end

class Conversations::Acknowledgement
  def self.call(conversation:, actor_user:, work_unit_token:, at: Time.current)
    raise ActiveRecord::RecordNotFound unless conversation.account_id == actor_user.account_id

    conversation = conversation.canonical
    conversation.with_lock do
      snapshot = Conversations::WorkUnitSnapshot.verify!(
        token: work_unit_token,
        conversation:
      )
      conversation.clear_attention!(
        actor_user:,
        at:,
        metadata: { "outcome" => "handled" },
        visible_message_ids: snapshot.fetch("message_ids")
      )
    end
    Conversations::Attention.recompute!(
      conversation:,
      actor_user:,
      at:
    )
  end
end

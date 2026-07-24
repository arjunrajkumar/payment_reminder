class Conversations::Acknowledgement
  def self.call(conversation:, actor_user:, work_unit_token:, at: Time.current)
    raise ActiveRecord::RecordNotFound unless conversation.account_id == actor_user.account_id

    conversation = conversation.canonical
    conversation.with_lock do
      snapshot = Conversations::WorkUnitSnapshot.verify!(
        token: work_unit_token,
        conversation:
      )
      execution_issues = snapshot.fetch("execution_issues", [])
      execution_issues.each do |issue|
        execution = ConversationActionExecution.lock.find(
          issue.fetch("id")
        )
        exact = execution.attention_required? &&
          execution.attention_version == issue.fetch("attention_version") &&
          execution.status == issue.fetch("status") &&
          execution.lock_version == issue.fetch("lock_version")
        unless exact
          raise Conversations::WorkUnitSnapshot::Stale,
            Conversations::WorkUnitSnapshot::ERROR_MESSAGE
        end
      end
      execution_issues.each do |issue|
        ConversationActionExecution.find(issue.fetch("id"))
          .acknowledge_attention!(
            expected_version: issue.fetch("attention_version")
          )
      end
      conversation.clear_attention!(
        actor_user:,
        at:,
        metadata: {
          "outcome" => "handled",
          "execution_issues" => execution_issues
        },
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

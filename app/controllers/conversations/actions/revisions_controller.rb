class Conversations::Actions::RevisionsController < Conversations::Actions::BaseController
  def create
    attributes = revision_params
    ConversationActions::Revision.record!(
      action: conversation_action,
      author_kind: :user,
      author_user: Current.user,
      user_facing_summary: attributes.fetch(:user_facing_summary),
      rationale: attributes[:rationale],
      base_revision_id: attributes[:base_revision_id].presence ||
        conversation_action.current_revision.id,
      proposed_reply_subject: attributes[:proposed_reply_subject].to_s,
      proposed_reply_body: attributes[:proposed_reply_body].to_s,
      idempotency_key: attributes.fetch(:idempotency_key),
      snapshot_token: attributes.fetch(:action_snapshot)
    )
    redirect_success("Action proposal revised.")
  rescue ConversationActions::Error,
    ActiveRecord::RecordInvalid,
    ArgumentError => error
    redirect_error(error)
  end

  private
    def revision_params
      params.require(:revision).permit(
        :user_facing_summary,
        :rationale,
        :base_revision_id,
        :proposed_reply_subject,
        :proposed_reply_body,
        :idempotency_key,
        :action_snapshot
      )
    end
end

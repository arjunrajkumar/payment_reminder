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
      arguments: attributes[:arguments]&.to_h || {},
      greeting: attributes[:greeting],
      closing: attributes[:closing],
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
        :greeting,
        :closing,
        :idempotency_key,
        :action_snapshot,
        arguments: %i[promised_on email mode]
      )
    end
end

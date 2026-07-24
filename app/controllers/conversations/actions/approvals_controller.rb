class Conversations::Actions::ApprovalsController < Conversations::Actions::BaseController
  def create
    attributes = approval_params
    revision = conversation_action.revisions.find(
      attributes.fetch(:revision_id)
    )
    ConversationActions::Approval.call(
      action: conversation_action,
      revision:,
      actor_user: Current.user,
      note: attributes[:note],
      idempotency_key: attributes.fetch(:idempotency_key),
      snapshot_token: attributes.fetch(:action_snapshot)
    )
    redirect_success("Action approved. Nothing has been sent or executed.")
  rescue ConversationActions::Error,
    ActiveRecord::RecordInvalid,
    ArgumentError => error
    redirect_error(error)
  end

  private
    def approval_params
      params.require(:approval).permit(
        :revision_id,
        :note,
        :idempotency_key,
        :action_snapshot
      )
    end
end

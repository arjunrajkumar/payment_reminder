class Conversations::Actions::RejectionsController < Conversations::Actions::BaseController
  def create
    attributes = rejection_params
    revision = conversation_action.revisions.find(
      attributes.fetch(:revision_id)
    )
    ConversationActions::Rejection.call(
      action: conversation_action,
      revision:,
      actor_user: Current.user,
      rationale: attributes.fetch(:rationale),
      idempotency_key: attributes.fetch(:idempotency_key),
      snapshot_token: attributes.fetch(:action_snapshot)
    )
    redirect_success("Action rejected.")
  rescue ConversationActions::Error,
    ActiveRecord::RecordInvalid,
    ArgumentError => error
    redirect_error(error)
  end

  private
    def rejection_params
      params.require(:rejection).permit(
        :revision_id,
        :rationale,
        :idempotency_key,
        :action_snapshot
      )
    end
end

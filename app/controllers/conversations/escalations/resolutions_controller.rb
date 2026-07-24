class Conversations::Escalations::ResolutionsController < ApplicationController
  def create
    conversation = Conversations::ReviewWorkUnit.reconcile_workflow_owner!(
      conversation: Current.account.conversations.find(
        params[:conversation_id]
      )
    )
    escalation = Current.account.conversation_escalations
      .where(
        conversation_id: Conversations::ReviewWorkUnit
          .workflow_conversation_ids_for(conversation:)
      )
      .find(params[:escalation_id])
    attributes = resolution_params
    escalation.resolve!(
      actor_user: Current.user,
      resolution_note: attributes.fetch(:resolution_note),
      idempotency_key: attributes.fetch(:idempotency_key),
      snapshot_token: attributes.fetch(:escalation_snapshot)
    )

    redirect_to conversation_path(conversation),
      notice: "Escalation resolved."
  rescue ConversationEscalations::Error,
    ActiveRecord::RecordInvalid,
    ArgumentError => error
    redirect_to conversation_path(conversation), alert: error.message
  end

  private
    def resolution_params
      params.require(:resolution).permit(
        :resolution_note,
        :idempotency_key,
        :escalation_snapshot
      )
    end
end

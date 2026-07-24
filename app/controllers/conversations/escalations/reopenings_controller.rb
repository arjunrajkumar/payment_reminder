class Conversations::Escalations::ReopeningsController < ApplicationController
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
    attributes = reopening_params
    escalation.reopen!(
      actor_user: Current.user,
      idempotency_key: attributes.fetch(:idempotency_key),
      snapshot_token: attributes.fetch(:escalation_snapshot)
    )

    redirect_to conversation_path(conversation),
      notice: "Escalation reopened."
  rescue ConversationEscalations::Error,
    ActiveRecord::RecordInvalid,
    ArgumentError => error
    redirect_to conversation_path(conversation), alert: error.message
  end

  private
    def reopening_params
      params.require(:reopening).permit(
        :idempotency_key,
        :escalation_snapshot
      )
    end
end

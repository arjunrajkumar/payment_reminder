class Conversations::EscalationsController < ApplicationController
  def create
    conversation = Conversations::ReviewWorkUnit.reconcile_workflow_owner!(
      conversation: Current.account.conversations.find(
        params[:conversation_id]
      )
    )
    attributes = escalation_params
    ConversationEscalations::Opening.call(
      conversation:,
      category: attributes.fetch(:category),
      priority: attributes.fetch(:priority),
      summary: attributes.fetch(:summary),
      details: attributes[:details],
      opened_by_kind: :user,
      opened_by_user: Current.user,
      idempotency_key: attributes.fetch(:idempotency_key)
    )

    redirect_to conversation_path(conversation),
      notice: "Conversation escalated for human review."
  rescue ConversationEscalations::Error,
    ActiveRecord::RecordInvalid,
    ArgumentError => error
    redirect_to conversation_path(conversation), alert: error.message
  end

  private
    def escalation_params
      params.require(:escalation).permit(
        :category,
        :priority,
        :summary,
        :details,
        :idempotency_key
      )
    end
end

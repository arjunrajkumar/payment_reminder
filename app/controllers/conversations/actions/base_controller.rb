class Conversations::Actions::BaseController < ApplicationController
  private
    def conversation
      @conversation ||= Conversations::ReviewWorkUnit
        .reconcile_workflow_owner!(
          conversation: Current.account.conversations.find(
            params[:conversation_id]
          )
        )
    end

    def conversation_action
      @conversation_action ||= Current.account.conversation_actions
        .where(
          conversation_id: Conversations::ReviewWorkUnit
            .workflow_conversation_ids_for(conversation:)
        )
        .find(params[:action_id])
    end

    def redirect_success(message)
      redirect_to conversation_path(conversation), notice: message
    end

    def redirect_error(error)
      redirect_to conversation_path(conversation), alert: error.message
    end
end

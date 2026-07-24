class Conversations::AiAnalysesController < ApplicationController
  before_action :set_conversation

  def create
    Conversations::WorkUnitSnapshot.verify!(
      token: analysis_params.fetch(:work_unit_token),
      conversation: @conversation
    )
    message = Current.account.conversation_messages.find(
      analysis_params.fetch(:source_message_id)
    )
    raise ActiveRecord::RecordNotFound unless
      Conversations::ReviewWorkUnit.includes_message?(
        conversation: @conversation,
        message:
      )

    interpretation = ConversationAi::AnalysisRequest.enqueue_for(
      message,
      requested_by: Current.user,
      reanalysis: true
    )
    if interpretation
      redirect_to conversation_path(@conversation), notice: "AI reanalysis queued."
    else
      redirect_to conversation_path(@conversation),
        alert: "This message is not eligible for AI analysis."
    end
  rescue Conversations::WorkUnitSnapshot::Stale => error
    redirect_to conversation_path(@conversation), alert: error.message
  end

  private
    def set_conversation
      @conversation = Current.account.conversations.find(
        params[:conversation_id]
      ).canonical
    end

    def analysis_params
      params.expect(ai_analysis: %i[source_message_id work_unit_token])
    end
end

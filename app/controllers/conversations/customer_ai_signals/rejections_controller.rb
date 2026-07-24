class Conversations::CustomerAiSignals::RejectionsController < ApplicationController
  def create
    conversation = Current.account.conversations.find(params[:conversation_id]).canonical
    signal = Current.account.customer_ai_signals.find(params[:customer_ai_signal_id])
    raise ActiveRecord::RecordNotFound unless
      signal.conversation_interpretation.conversation.canonical == conversation
    attributes = rejection_params
    CustomerAi::GuidanceDecision.reject!(
      signal:,
      actor_user: Current.user,
      token: attributes.fetch(:token),
      idempotency_key: attributes.fetch(:idempotency_key),
      note: attributes[:note]
    )
    redirect_to conversation_path(conversation), notice: "Customer guidance suggestion rejected."
  rescue CustomerAi::GuidanceSnapshot::Stale,
    CustomerAi::GuidanceDecision::Conflict => error
    redirect_to conversation_path(params[:conversation_id]), alert: error.message
  end

  private
    def rejection_params
      params.expect(customer_ai_signal_rejection: %i[
        token idempotency_key note
      ])
    end
end

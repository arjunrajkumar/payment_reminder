class Conversations::CustomerAiSignals::ApprovalsController < ApplicationController
  def create
    conversation = Current.account.conversations.find(params[:conversation_id]).canonical
    signal = Current.account.customer_ai_signals.find(params[:customer_ai_signal_id])
    raise ActiveRecord::RecordNotFound unless
      signal.conversation_interpretation.conversation.canonical == conversation
    attributes = approval_params
    CustomerAi::GuidanceDecision.approve!(
      signal:,
      actor_user: Current.user,
      token: attributes.fetch(:token),
      idempotency_key: attributes.fetch(:idempotency_key),
      summary: attributes.fetch(:summary),
      structured_guidance: guidance_params,
      note: attributes[:note]
    )
    redirect_to conversation_path(conversation), notice: "Customer guidance activated."
  rescue CustomerAi::GuidanceSnapshot::Stale,
    CustomerAi::GuidanceDecision::Conflict,
    ActiveRecord::RecordInvalid => error
    redirect_to conversation_path(params[:conversation_id]), alert: error.message
  end

  private
    def approval_params
      params.expect(customer_ai_signal_approval: %i[
        token idempotency_key summary note
      ])
    end

    def guidance_params
      params.expect(customer_ai_signal_approval: {
        structured_guidance: CustomerAiGuidanceRevision::ALLOWED_GUIDANCE_KEYS
      }).fetch(:structured_guidance, {})
    end
end

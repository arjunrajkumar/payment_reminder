class Conversations::AiEvaluationsController < ApplicationController
  before_action :set_conversation

  def create
    interpretation = Current.account.conversation_interpretations.find(
      params[:conversation_interpretation_id]
    )
    raise ActiveRecord::RecordNotFound unless
      interpretation.conversation.canonical == @conversation
    attributes = evaluation_params
    ConversationAi::EvaluationRecorder.record!(
      interpretation:,
      actor_user: Current.user,
      token: attributes.fetch(:token),
      idempotency_key: attributes.fetch(:idempotency_key),
      verdict: attributes.fetch(:verdict),
      corrected_message_kind: attributes[:corrected_message_kind],
      corrected_action_type: attributes[:corrected_action_type],
      corrected_arguments: parsed_json(attributes[:corrected_arguments]),
      note: attributes[:note]
    )
    redirect_to conversation_path(@conversation), notice: "AI feedback recorded."
  rescue ConversationAi::EvaluationSnapshot::Stale,
    ConversationAi::EvaluationRecorder::Conflict,
    ConversationActions::Catalog::InvalidAction,
    ArgumentError => error
    redirect_to conversation_path(@conversation), alert: error.message
  end

  private
    def set_conversation
      @conversation = Current.account.conversations.find(
        params[:conversation_id]
      ).canonical
    end

    def evaluation_params
      params.expect(ai_evaluation: %i[
        token idempotency_key verdict corrected_message_kind
        corrected_action_type corrected_arguments note
      ])
    end

    def parsed_json(value)
      return {} if value.blank?

      JSON.parse(value)
    rescue JSON::ParserError
      raise ArgumentError, "Corrected arguments must be valid JSON."
    end
end

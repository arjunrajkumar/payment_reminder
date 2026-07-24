class ConversationAi::EvaluationRecorder
  class Conflict < StandardError; end

  class << self
    def record!(
      interpretation:,
      actor_user:,
      token:,
      idempotency_key:,
      verdict:,
      corrected_message_kind: nil,
      corrected_action_type: nil,
      corrected_arguments: {},
      note: nil
    )
      new(
        interpretation:,
        actor_user:,
        token:,
        idempotency_key:,
        verdict:,
        corrected_message_kind:,
        corrected_action_type:,
        corrected_arguments:,
        note:
      ).record!
    end
  end

  def initialize(**attributes)
    attributes.each { |key, value| instance_variable_set("@#{key}", value) }
  end

  def record!
    validate_input!
    ConversationAi::EvaluationSnapshot.verify!(
      token:,
      interpretation:,
      idempotency_key:
    )
    interpretation.with_lock do
      if existing = interpretation.account.conversation_ai_evaluations
          .find_by(idempotency_key:)
        return existing if replay_matches?(existing)

        raise Conflict, "That feedback key was already used for different feedback."
      end
      previous = interpretation.conversation_ai_evaluations.latest
        .order(created_at: :desc, id: :desc)
        .first
      evaluation = interpretation.conversation_ai_evaluations.create!(
        account: interpretation.account,
        conversation_ai_plan: interpretation.conversation_ai_plan,
        actor_user:,
        actor_snapshot: ConversationAi::ActorSnapshot.for(actor_user),
        verdict:,
        corrected_message_kind: corrected_message_kind.presence,
        corrected_action_type: corrected_action_type.presence,
        corrected_arguments: corrected_arguments.to_h.deep_stringify_keys,
        note: note.to_s.strip.presence,
        idempotency_key:,
        supersedes_evaluation: previous
      )
      ConversationEvent.record_ai_once!(
        interpretation:,
        role: "evaluation:#{evaluation.id}",
        kind: :conversation_ai_evaluation_recorded,
        actor_kind: :user,
        actor_user:,
        metadata: {
          "conversation_ai_evaluation_id" => evaluation.id,
          "verdict" => evaluation.verdict
        }
      )
      evaluation
    end
  end

  private
    attr_reader :interpretation,
      :actor_user,
      :token,
      :idempotency_key,
      :verdict,
      :corrected_message_kind,
      :corrected_action_type,
      :corrected_arguments,
      :note

    def validate_input!
      raise ActiveRecord::RecordNotFound unless
        interpretation.account_id == actor_user.account_id
      unless verdict.to_s.in?(ConversationAiEvaluation::VERDICTS.keys)
        raise ArgumentError, "Choose correct, incorrect, or unsure."
      end
      if corrected_message_kind.present? &&
          !corrected_message_kind.in?(ConversationAi::OutputSchema::MESSAGE_KINDS)
        raise ArgumentError, "Corrected message kind is unsupported."
      end
      if corrected_action_type.present?
        ConversationActions::Catalog.validate!(
          action_type: corrected_action_type,
          arguments: corrected_arguments.to_h.deep_stringify_keys,
          proposed_reply: {}
        )
      elsif corrected_arguments.to_h.present?
        raise ArgumentError, "Corrected arguments require an action type."
      end
    end

    def replay_matches?(existing)
      existing.verdict == verdict.to_s &&
        existing.corrected_message_kind == corrected_message_kind.presence &&
        existing.corrected_action_type == corrected_action_type.presence &&
        existing.corrected_arguments == corrected_arguments.to_h.deep_stringify_keys &&
        existing.note == note.to_s.strip.presence &&
        existing.actor_snapshot == ConversationAi::ActorSnapshot.for(actor_user)
    end
end

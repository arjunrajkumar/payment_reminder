class ConversationActions::Commands::OpenDispute <
    ConversationActions::Commands::Base
  def call
    escalation = conversation.conversation_escalations
      .status_open
      .category_dispute
      .where(invoice:)
      .where.not(collection_hold_id: nil)
      .includes(:collection_hold)
      .reorder(:id)
      .detect { |item| item.collection_hold&.status_active? }
    hold = escalation&.collection_hold
    mutated = false

    unless hold
      hold = invoice.collection_holds.status_active.reason_dispute
        .reorder(:id).first
      unless hold
        hold = CollectionHolds::Placement.call(
        conversation:,
        reason: :dispute,
        source_message:,
        conversation_action: action,
        placed_by_kind: :system,
        idempotency_key: "action-execution:#{execution.id}:dispute-hold",
          at:
        )
        mutated = true
      end
      escalation = open_escalation!(
        category: :dispute,
        priority: :high,
        summary: "Customer disputed invoice #{invoice.number.presence || invoice.external_id}.",
        collection_hold: hold,
        suffix: "dispute-escalation"
      )
      mutated = true
    end

    result(
      result_code: mutated ? "dispute_opened" : "dispute_already_open",
      result_metadata: {
        "outcome" => mutated ? "dispute_opened" : "dispute_already_open"
      },
      collection_hold: hold,
      effect_escalation: escalation,
      effect_mutated: mutated,
      rendered_reply: render_reply(
        outcome: {
          "outcome" => mutated ? "dispute_opened" : "dispute_already_open"
        }
      ),
      attention_required: true
    )
  end
end

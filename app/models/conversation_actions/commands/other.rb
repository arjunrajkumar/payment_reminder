class ConversationActions::Commands::Other <
    ConversationActions::Commands::Base
  def call
    escalation = open_escalation!(
      summary: "Approved action requires human handling.",
      details: "No autonomous product action or reply was performed.",
      suffix: "other"
    )
    result(
      result_code: "human_escalation_required",
      effect_escalation: escalation,
      effect_mutated: true,
      attention_required: true
    )
  end
end

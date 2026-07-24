class ConversationActions::Commands::FactualAnswer <
    ConversationActions::Commands::Base
  def call
    result(
      result_code: "#{definition.action_type}_rendered",
      rendered_reply: render_reply,
      effect_mutated: false
    )
  end
end

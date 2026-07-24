class ConversationActions::Commands::Dispatcher
  COMMANDS = {
    "record_payment_promise" =>
      ConversationActions::Commands::RecordPaymentPromise,
    "answer_due_date" =>
      ConversationActions::Commands::FactualAnswer,
    "answer_payment_status" =>
      ConversationActions::Commands::FactualAnswer,
    "answer_outstanding_amount" =>
      ConversationActions::Commands::FactualAnswer,
    "resend_invoice" =>
      ConversationActions::Commands::FactualAnswer,
    "add_recipient" =>
      ConversationActions::Commands::AddRecipient,
    "open_dispute" =>
      ConversationActions::Commands::OpenDispute,
    "other" =>
      ConversationActions::Commands::Other
  }.freeze

  def self.call(**attributes)
    definition = attributes.fetch(:definition)
    COMMANDS.fetch(definition.action_type).call(**attributes)
  end
end

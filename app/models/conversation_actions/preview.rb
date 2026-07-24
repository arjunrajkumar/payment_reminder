class ConversationActions::Preview
  Preview = Data.define(:subject, :body, :recipient, :cc_addresses, :available)

  def self.for(action)
    revision = action.current_revision
    definition = ConversationActions::Catalog.validate!(
      action_type: action.action_type,
      arguments: revision.arguments,
      proposed_reply: revision.proposed_reply
    )
    return Preview.new(
      subject: nil,
      body: nil,
      recipient: nil,
      cc_addresses: [],
      available: false
    ) unless definition.reply?

    invoice = revision.invoice
    rendered = ConversationActions::ReplyRenderer.render!(
      definition:,
      invoice:,
      account: action.account,
      at: Time.current,
      outcome: preview_outcome(
        definition:,
        action:,
        invoice:
      )
    )
    cc = if definition.action_type == "add_recipient" &&
        definition.arguments.fetch("mode") == "cc_current_reply"
      [ definition.arguments.fetch("email") ]
    else
      []
    end
    composition = ConversationActions::ReplyComposer.compose!(
      conversation: action.conversation,
      reply_to_message: action.source_message,
      rendered_reply: rendered,
      cc_addresses: cc
    )
    Preview.new(
      subject: composition.subject,
      body: composition.body,
      recipient: composition.to_addresses.first,
      cc_addresses: composition.cc_addresses,
      available: true
    )
  rescue ConversationActions::Error,
    ActiveRecord::RecordNotFound,
    KeyError,
    NoMethodError
    Preview.new(
      subject: nil,
      body: nil,
      recipient: nil,
      cc_addresses: [],
      available: false
    )
  end

  def self.preview_outcome(definition:, action:, invoice:)
    return {} unless definition.action_type == "add_recipient"

    email = definition.arguments.fetch("email")
    mode = definition.arguments.fetch("mode")
    outcome = if mode == "future_reminders"
      if invoice.customer.synced_reminder_email_address == email
        "already_primary"
      elsif invoice.customer.additional_email_addresses.exists?(email:)
        "already_present"
      else
        "added"
      end
    else
      target = ConversationMessages::ManualReply.reply_target_for(
        conversation: action.conversation,
        reply_to_message: action.source_message
      )
      target&.recipient == email ? "already_copied" : "copied"
    end
    { "email" => email, "mode" => mode, "outcome" => outcome }
  end
  private_class_method :preview_outcome
end

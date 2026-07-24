class ConversationActions::Commands::AddRecipient <
    ConversationActions::Commands::Base
  def call
    email = definition.arguments.fetch("email")
    mode = definition.arguments.fetch("mode")
    address, outcome, mutated = if mode == "future_reminders"
      persist_address(email)
    else
      current_recipient_outcome(email)
    end
    cc_addresses = mode == "cc_current_reply" && outcome == "copied" ?
      [ email ] :
      []

    result(
      result_code: outcome_code(mode:, outcome:),
      result_metadata: {
        "email" => email,
        "mode" => mode,
        "outcome" => outcome
      },
      customer_email_address: address,
      effect_mutated: mutated,
      rendered_reply: render_reply(
        outcome: {
          "email" => email,
          "mode" => mode,
          "outcome" => outcome
        }
      ),
      cc_addresses:
    )
  end

  private
    def persist_address(email)
      customer = invoice.customer
      return [ nil, "already_primary", false ] if
        customer.synced_reminder_email_address == email

      existing = customer.additional_email_addresses.find_by(email:)
      return [ existing, "already_present", false ] if existing

      address = customer.additional_email_addresses.create!(email:)
      [ address, "added", true ]
    rescue ActiveRecord::RecordNotUnique
      [
        customer.additional_email_addresses.find_by!(email:),
        "already_present",
        false
      ]
    rescue ActiveRecord::RecordInvalid => error
      existing = customer.additional_email_addresses.find_by(email:)
      return [ existing, "already_present", false ] if existing

      raise error
    end

    def current_recipient_outcome(email)
      target = ConversationMessages::ManualReply.reply_target_for(
        conversation:,
        reply_to_message: source_message
      )
      target&.recipient == email ?
        [ nil, "already_copied", false ] :
        [ nil, "copied", false ]
    end

    def outcome_code(mode:, outcome:)
      return "future_reminder_recipient_#{outcome}" if
        mode == "future_reminders"

      "current_reply_recipient_#{outcome}"
    end
end

class ConversationReplyMailer < ApplicationMailer
  def reply(conversation_message)
    @conversation_message = conversation_message

    headers[
      "In-Reply-To"
    ] = conversation_message.in_reply_to_message_ids.join(" ")
    headers[
      "References"
    ] = conversation_message.reference_message_ids.join(" ")

    mail(
      to: conversation_message.to_addresses.sole,
      cc: conversation_message.cc_addresses.presence,
      from: conversation_message.from_address,
      subject: conversation_message.subject
    ) do |format|
      format.text
    end
  end
end

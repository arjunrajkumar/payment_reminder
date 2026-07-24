class ConversationActions::ReplyComposer
  Composition = Data.define(
    :to_addresses,
    :cc_addresses,
    :subject,
    :body
  )

  def self.compose!(
    conversation:,
    reply_to_message:,
    rendered_reply:,
    cc_addresses:
  )
    target = ConversationMessages::ManualReply.reply_target_for(
      conversation:,
      reply_to_message:
    )
    raise ConversationMessages::ManualReply::UnsafeAnchor,
      "This email cannot be replied to safely." unless target

    recipient = target.recipient
    cc = Array(cc_addresses).filter_map do |address|
      normalized = address.to_s.strip.downcase.presence
      next if normalized == recipient
      next unless normalized&.match?(URI::MailTo::EMAIL_REGEXP)
      next if normalized.match?(/[\r\n]/)

      normalized
    end.uniq
    original = reply_to_message.subject.to_s.strip.presence
    rendered = rendered_reply.subject.to_s.strip.presence
    base = original || rendered || "Invoice update"
    subject = base.match?(/\Are:/i) ? base : "Re: #{base}"

    Composition.new(
      to_addresses: [ recipient ],
      cc_addresses: cc,
      subject:,
      body: rendered_reply.body
    )
  end
end

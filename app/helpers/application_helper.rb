module ApplicationHelper
  def page_title_tag
    tag.title [ @page_title, Current.account&.name, "PaymentReminder" ].compact.uniq.join(" | ")
  end

  def body_classes
    [ @body_class ].compact.join(" ")
  end

  def conversation_name(conversation, latest_inbound_sender: nil)
    conversation.customer&.name.presence ||
      conversation.invoice&.contact_name.presence ||
      latest_inbound_sender.presence ||
      "Unmatched email"
  end

  def manual_match_available?(message)
    source = message.conversation
    source.invoice_id.nil? && source.canonical_conversation_id.nil?
  end

  def conversation_invoice_reference(conversation)
    invoice = conversation.invoice
    return "No invoice matched" unless invoice

    invoice.number.presence || invoice.external_id
  end

  def conversation_message_status(message)
    return "Delivery not confirmed" if message.delivery_uncertain?
    return "Received" if message.status_received?
    return "Sending" if message.status_pending?
    return "Sent" if message.status_sent?

    "Failed"
  end

  def conversation_event_label(event)
    {
      "conversation_message_reviewed" => "Review completed",
      "conversation_message_review_corrected" => "Review corrected",
      "conversation_attention_cleared" => "Marked handled",
      "conversation_manually_matched" => "Conversation matched",
      "conversations_linked" => "Conversation linked",
      "conversation_manual_reply_queued" => "Reply queued",
      "conversation_manual_reply_sent" => "Reply sent",
      "conversation_manual_reply_failed" => "Reply failed",
      "conversation_manual_reply_unconfirmed" => "Reply delivery not confirmed",
      "conversation_action_created" => "Action proposed",
      "conversation_action_revised" => "Action proposal revised",
      "conversation_action_approved" => "Action approved",
      "conversation_action_rejected" => "Action rejected",
      "collection_hold_placed" => "Automated collection paused",
      "collection_hold_released" => "Collection hold released",
      "conversation_escalated" => "Conversation escalated",
      "conversation_escalation_resolved" => "Escalation resolved",
      "conversation_escalation_reopened" => "Escalation reopened",
      "invoice_reminder_notifications_finalized" =>
        "Reminder notifications finalized",
      "conversation_resolved" => "Conversation resolved",
      "conversation_reopened" => "Conversation reopened"
    }.fetch(event.kind, "Conversation updated")
  end

  def conversation_event_detail(event)
    if event.kind_conversation_escalation_resolved?
      rationale = event.metadata["rationale"].to_s.strip
      "Resolution: #{rationale}" if rationale.present?
    elsif event.kind_conversation_escalation_reopened?
      "Escalation reopened for another review."
    elsif event.kind_collection_hold_placed? &&
        event.metadata["in_flight_delivery_message_ids"].present?
      in_flight_delivery_warning
    elsif event.kind_invoice_reminder_notifications_finalized?
      notification_delivery_counts(event)
    end
  end

  def notification_delivery_counts(event)
    labels = {
      "delivered_count" => "Delivered",
      "uncertain_count" => "Unconfirmed",
      "failed_count" => "Failed",
      "canceled_count" => "Canceled"
    }
    labels.map do |key, label|
      "#{label}: #{event.metadata[key].to_i}"
    end.join(" · ")
  end

  def in_flight_delivery_warning
    "An email had already started sending when this hold was placed and may still arrive."
  end
end

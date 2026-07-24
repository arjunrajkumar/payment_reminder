class ConversationMessages::ActionReply
  class IdempotencyConflict < ConversationActions::Error; end

  def self.reserve!(**attributes)
    new(**attributes).reserve!
  end

  def initialize(execution:, conversation:, reply_to_message:, kind:, rendered_reply:, cc_addresses:, at:)
    @execution = execution
    @conversation = conversation.canonical
    @reply_to_message = reply_to_message
    @kind = kind.to_s
    @rendered_reply = rendered_reply
    @cc_addresses = Array(cc_addresses)
    @at = at
    @account = @conversation.account
  end

  def reserve!
    existing = execution.conversation_message
    return validate_existing!(existing) if existing

    ConversationMessages::ThreadedReply.ensure_fresh!(
      conversation:,
      reply_to_message:
    )
    connection = delivery_connection!
    composition = ConversationActions::ReplyComposer.compose!(
      conversation:,
      reply_to_message:,
      rendered_reply:,
      cc_addresses:
    )
    message = conversation.conversation_messages.create!(
      account:,
      invoice: conversation.invoice,
      email_connection: connection,
      email_connection_generation: connection.credential_generation,
      provider_account_id: connection.provider_account_id,
      requested_provider_account_id: reply_to_message.provider_account_id,
      requested_provider_thread_id: reply_to_message.provider_thread_id,
      reply_to_message:,
      actor_user: execution.approved_by_user,
      actor_snapshot: execution.approver_snapshot,
      conversation_action_execution: execution,
      direction: :outbound,
      kind:,
      status: :pending,
      reply_scheduling_status: :reserved,
      next_reply_scheduling_at: at,
      from_address: connection.connected_email,
      to_addresses: composition.to_addresses,
      cc_addresses: composition.cc_addresses,
      bcc_addresses: [],
      reply_to_addresses: [],
      subject: composition.subject,
      body: composition.body,
      in_reply_to_message_ids: [ reply_to_message.internet_message_id ],
      reference_message_ids: reply_references,
      matching_status: :matched,
      matching_method: :gmail_thread,
      idempotency_key: "action-execution:#{execution.id}:reply"
    )
    ConversationEvent.record_execution_once!(
      execution:,
      role: "reply_reserved",
      conversation_message: message,
      kind: :conversation_action_reply_queued,
      metadata: {
        "reply_to_message_id" => reply_to_message.id,
        "recipient" => composition.to_addresses.first,
        "cc_addresses" => composition.cc_addresses,
        "reply_kind" => kind
      },
      created_at: at
    )
    message
  rescue ActiveRecord::RecordNotUnique
    validate_existing!(execution.reload.conversation_message)
  end

  private
    attr_reader :execution,
      :conversation,
      :reply_to_message,
      :kind,
      :rendered_reply,
      :cc_addresses,
      :at,
      :account

    def validate_existing!(message)
      exact = message &&
        message.conversation_action_execution_id == execution.id &&
        message.reply_to_message_id == reply_to_message.id &&
        message.kind == kind &&
        message.body == rendered_reply.body
      raise IdempotencyConflict, "Action reply identity was already used." unless exact

      message
    end

    def delivery_connection!
      connection = account.email_connection
      ready = connection&.gmail_ready? &&
        connection.sender_matches?(account.invoice_reminder_from_email) &&
        connection.provider_account_id == reply_to_message.provider_account_id
      unless ready
        raise ConversationMessages::ManualReply::DeliveryUnavailable,
          "Gmail is not ready for replies."
      end
      connection
    end

    def reply_references
      [
        *reply_to_message.reference_message_ids,
        *reply_to_message.in_reply_to_message_ids,
        reply_to_message.internet_message_id
      ].compact.uniq
    end
end

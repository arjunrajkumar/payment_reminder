class Conversations::Timeline
  Item = Data.define(:type, :record, :occurred_at)

  HIDDEN_EVENT_KINDS = %w[
    conversation_message_received
    conversation_message_imported
    conversation_created
  ].freeze

  def initialize(conversation:)
    @conversation = conversation.canonical
  end

  def messages
    @messages ||= Conversations::ReviewWorkUnit
      .message_scope_for_conversation(conversation:)
      .chronological
      .to_a
  end

  def events
    @events ||= conversation.account.conversation_events
      .where(
        conversation_id: Conversations::ReviewWorkUnit
          .workflow_conversation_ids_for(conversation:)
      )
      .where.not(kind: HIDDEN_EVENT_KINDS)
      .chronological
      .to_a
  end

  def items
    message_items = messages.map { |message| Item.new(type: :message, record: message, occurred_at: message.occurred_at) }
    event_items = events.map { |event| Item.new(type: :event, record: event, occurred_at: event.created_at) }

    (message_items + event_items).sort_by do |item|
      [ item.occurred_at, item.type == :message ? 0 : 1, item.record.id ]
    end
  end

  private
    attr_reader :conversation
end

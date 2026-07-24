class Conversations::Detail
  attr_reader :conversation, :timeline

  def self.call(conversation:)
    new(conversation:)
  end

  def initialize(conversation:)
    @conversation = Conversations::ReviewWorkUnit.reconcile_workflow_owner!(
      conversation:
    )
    @timeline = Conversations::Timeline.new(conversation: @conversation)
  end

  def reply_targets
    return [] unless conversation.invoice

    provider_account_id = conversation.account.email_connection&.provider_account_id
    return [] if provider_account_id.blank?

    timeline.messages
      .select do |message|
        message.direction_inbound? &&
          message.provider_account_id == provider_account_id &&
          message.provider_thread_id.present?
      end
      .group_by { |message| [ message.provider_account_id, message.provider_thread_id ] }
      .filter_map do |_thread, messages|
        messages.reverse_each.filter_map do |message|
          ConversationMessages::ManualReply.reply_target_for(
            conversation:,
            reply_to_message: message
          )
        end.first
      end
      .sort_by { |target| [ target.message.occurred_at, target.message.id ] }
  end

  def actions
    @actions ||= conversation.account.conversation_actions
      .where(
        conversation_id: Conversations::ReviewWorkUnit
          .workflow_conversation_ids_for(conversation:)
      )
      .includes(
        :created_by_user,
        :decided_by_user,
        :source_message,
        execution: [
          :approved_by_user,
          :conversation_message,
          :payment_promise,
          :customer_email_address,
          :collection_hold,
          :effect_escalation,
          :delivery_escalation
        ],
        revisions: [
          :author_user,
          :customer,
          { invoice: [ :customer, :invoice_source ] }
        ]
      )
      .order(created_at: :desc, id: :desc)
      .to_a
  end

  def collection_holds
    @collection_holds ||= conversation.collection_holds
      .includes(:placed_by_user, :released_by_user)
      .order(
        Arel.sql("CASE WHEN status = 'active' THEN 0 ELSE 1 END"),
        placed_at: :desc,
        id: :desc
      )
      .to_a
  end

  def active_collection_holds
    collection_holds.select(&:status_active?)
  end

  def collection_held?
    active_collection_holds.any?
  end

  def escalations
    @escalations ||= conversation.account.conversation_escalations
      .where(
        conversation_id: Conversations::ReviewWorkUnit
          .workflow_conversation_ids_for(conversation:)
      )
      .includes(:opened_by_user, :resolved_by_user)
      .order(
        Arel.sql("CASE WHEN status = 'open' THEN 0 ELSE 1 END"),
        last_opened_at: :desc,
        id: :desc
      )
      .to_a
  end
end

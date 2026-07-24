class Conversations::Attention
  class << self
    def require_for_message!(message)
      requires_attention = message.awaiting_review? ||
        (message.direction_inbound? && message.status_received?)
      return unless requires_attention

      message.conversation.require_attention!(at: message.occurred_at)
    end

    def require_for_inbound!(message)
      require_for_message!(message)
    end

    def clear_for_outbound!(message)
      return unless message.direction_outbound? && message.status_sent?

      recompute!(
        conversation: message.conversation,
        at: message.occurred_at,
        metadata: {
          "cleared_by_message_id" => message.id,
          "provider_thread_id" => message.provider_thread_id
        }
      )
    end

    def recompute!(
      conversation:,
      actor_user: nil,
      at: Time.current,
      metadata: {}
    )
      target = Conversations::ReviewWorkUnit.workflow_owner_for(
        conversation:
      )
      conversation_ids = Conversations::ReviewWorkUnit
        .workflow_conversation_ids_for(conversation: target)
      Conversation.transaction do
        locked = target.account.conversations
          .where(id: conversation_ids)
          .order(:id)
          .lock
          .index_by(&:id)
        locked.each_value do |member|
          next if member.id == target.id
          next if member.attention_required_at.nil?

          member.update!(attention_required_at: nil)
        end
        target = locked.fetch(target.id)
        previous_attention_at = target.attention_required_at
        outstanding_at = outstanding_attention_at(target)
        unless previous_attention_at == outstanding_at
          target.update!(attention_required_at: outstanding_at)
          if previous_attention_at.present? && outstanding_at.nil?
            target.conversation_events.create!(
              account: target.account,
              kind: :conversation_attention_cleared,
              actor_kind: actor_user ? :user : :system,
              actor_user:,
              metadata:,
              created_at: at
            )
          end
        end
      end
      target
    end

    private
      def outstanding_attention_at(conversation)
        messages = Conversations::ReviewWorkUnit
          .message_scope_for_conversation(conversation:)
        [
          latest_review_attention(messages),
          latest_unanswered_inbound(messages, conversation),
          latest_manual_reply_failure(messages, conversation),
          latest_pending_action(conversation),
          latest_action_execution(conversation),
          latest_open_escalation(conversation),
          unknown_attention_at(messages, conversation)
        ].compact.max
      end

      def unknown_attention_at(messages, conversation)
        current = conversation.attention_required_at
        return unless current
        resolving_event_at = conversation.account.conversation_events
          .where(
            conversation_id: Conversations::ReviewWorkUnit
              .workflow_conversation_ids_for(conversation:)
          )
          .where(
            kind: %i[
              conversation_action_approved
              conversation_action_rejected
              conversation_escalation_resolved
            ]
          )
          .maximum(:created_at)
        return if resolving_event_at && current <= resolving_event_at

        latest_message_at = messages.maximum(
          Arel.sql("COALESCE(received_at, sent_at, created_at)")
        )
        current if current.present? &&
          (latest_message_at.nil? || current > latest_message_at)
      end

      def latest_review_attention(messages)
        messages.awaiting_review.maximum(
          Arel.sql("COALESCE(received_at, sent_at, created_at)")
        )
      end

      def latest_unanswered_inbound(messages, conversation)
        acknowledgement = latest_user_acknowledgement(conversation)
        inbound = messages.where(
          direction: ConversationMessage::DIRECTIONS.fetch(:inbound),
          kind: ConversationMessage::KINDS.fetch(:customer_email),
          status: ConversationMessage::STATUSES.fetch(:received)
        )
        inbound = inbound.where(review_required: false).or(
          inbound.where(
            review_outcome: ConversationMessage::REVIEW_OUTCOMES.fetch(:manual_match)
          )
        )
        if acknowledgement
          acknowledged_message_ids = Array(
            acknowledgement.metadata["visible_message_ids"]
          ).map(&:to_i)
          inbound = inbound.where.not(id: acknowledged_message_ids) if
            acknowledged_message_ids.any?
        end
        sent_by_thread = messages
          .where(
            direction: ConversationMessage::DIRECTIONS.fetch(:outbound),
            status: ConversationMessage::STATUSES.fetch(:sent)
          )
          .where.not(provider_account_id: nil, provider_thread_id: nil)
          .group(:provider_account_id, :provider_thread_id)
          .maximum(:sent_at)

        inbound.filter_map do |message|
          sent_at = sent_by_thread[
            [ message.provider_account_id, message.provider_thread_id ]
          ]
          message.received_at if sent_at.nil? || sent_at < message.received_at
        end.max
      end

      def latest_manual_reply_failure(messages, conversation)
        acknowledgement = latest_user_acknowledgement(conversation)
        events = conversation.account.conversation_events
          .where(
            conversation_id: Conversations::ReviewWorkUnit
              .conversation_ids_for(conversation:)
          )
          .where(
            kind: %i[
              conversation_manual_reply_failed
              conversation_manual_reply_unconfirmed
            ]
          )
          .includes(conversation_message: :reply_to_message)
        events = events.where("conversation_events.id > ?", acknowledgement.id) if
          acknowledgement

        events.filter_map do |event|
          next if event.conversation_message&.status_sent?

          event.conversation_message&.reply_to_message&.occurred_at ||
            event.created_at
        end.max
      end

      def latest_pending_action(conversation)
        conversation.account.conversation_actions
          .where(
            conversation_id: Conversations::ReviewWorkUnit
              .workflow_conversation_ids_for(conversation:)
          )
          .status_pending_approval
          .includes(:revisions)
          .filter_map { |action| action.current_revision&.created_at }
          .max
      end

      def latest_open_escalation(conversation)
        conversation.account.conversation_escalations
          .where(
            conversation_id: Conversations::ReviewWorkUnit
              .workflow_conversation_ids_for(conversation:)
          )
          .status_open
          .maximum(:last_opened_at)
      end

      def latest_action_execution(conversation)
        ConversationActionExecution
          .joins(:conversation_action)
          .where(
            conversation_actions: {
              conversation_id: Conversations::ReviewWorkUnit
                .workflow_conversation_ids_for(conversation:)
            },
            attention_required: true
          )
          .maximum(
            Arel.sql(
              "COALESCE(conversation_action_executions.finished_at, " \
                "conversation_action_executions.updated_at)"
            )
          )
      end

      def latest_user_acknowledgement(conversation)
        conversation.conversation_events
          .kind_conversation_attention_cleared
          .actor_kind_user
          .order(id: :desc)
          .detect { |event| event.metadata["outcome"] == "handled" }
      end
  end
end

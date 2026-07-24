class ConversationMessages::ThreadedReply
  ACTION_KINDS = %w[
    due_date_answer
    payment_status_answer
    outstanding_amount_answer
    invoice_resend
    payment_promise_acknowledgement
    dispute_acknowledgement
    recipient_update_acknowledgement
  ].freeze
  KINDS = ([ "manual_reply" ] + ACTION_KINDS).freeze

  class << self
    def action_kind?(kind)
      kind.to_s.in?(ACTION_KINDS)
    end

    def ensure_fresh!(conversation:, reply_to_message:)
      if newer_safe_inbound?(conversation:, reply_to_message:)
        raise ConversationMessages::ManualReply::StaleComposer,
          "A newer customer email arrived. Refresh before replying."
      end
      if conflicting_delivery?(conversation:, reply_to_message:)
        raise ConversationMessages::ManualReply::StaleComposer,
          "Another reply may already have been sent for this thread."
      end
    end

    private
      def newer_safe_inbound?(conversation:, reply_to_message:)
        account = conversation.account
        base = account.conversation_messages.where(
          conversation_id: conversation.conversation_group_ids,
          direction: :inbound,
          kind: :customer_email,
          status: :received,
          provider_account_id: reply_to_message.provider_account_id,
          provider_thread_id: reply_to_message.provider_thread_id,
          automatic: false
        )
        base.where(review_required: false)
          .or(base.where.not(reviewed_at: nil))
          .where(
            "received_at > :received_at OR " \
              "(received_at = :received_at AND id > :message_id)",
            received_at: reply_to_message.received_at,
            message_id: reply_to_message.id
          )
          .any? do |message|
            ConversationMessages::ManualReply.reply_target_for(
              conversation:,
              reply_to_message: message
            )
          end
      end

      def conflicting_delivery?(conversation:, reply_to_message:)
        conversation.account.conversation_messages
          .where(kind: KINDS)
          .where(
            requested_provider_account_id: reply_to_message.provider_account_id,
            requested_provider_thread_id: reply_to_message.provider_thread_id
          )
          .where(
            "status = :pending OR delivery_uncertain = TRUE",
            pending: ConversationMessage::STATUSES.fetch(:pending)
          )
          .exists?
      end
  end
end

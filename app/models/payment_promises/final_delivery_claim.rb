class PaymentPromises::FinalDeliveryClaim
  Result = Data.define(:reason, :context) do
    def claimed?
      reason.nil?
    end
  end

  def self.call(
    payment_promise:,
    message:,
    delivery_job_id:,
    cancel_if_hold_released: false
  )
    result = nil
    Receivables::AccountLock.synchronize(account: payment_promise.account) do
      payment_promise.invoice.with_lock do
        payment_promise.reload
        message.reload
        unless payment_promise.status_active? &&
            payment_promise.follow_up_message_id == message.id &&
            message.delivery_owned_by?(delivery_job_id)
          result = Result.new(
            reason: "delivery_state_changed",
            context: {}
          )
          next
        end

        holds = payment_promise.invoice.active_collection_holds.reorder(:id).to_a
        recent_contact = payment_promise.invoice.conversation_messages
          .successful_outbound
          .where.not(id: message.id)
          .sent_after(ConversationMessage::OUTBOUND_CONTACT_COOLDOWN.ago)
          .exists?
        if holds.empty? && recent_contact
          if PaymentPromises::PendingDeliveryCancellation.call(
            payment_promise:,
            message:,
            delivery_job_id:,
            failure_reason: "Promise follow-up was not sent because a newer outbound contact exists."
          )
            result = Result.new(
              reason: "recent_outbound_message",
              context: {}
            )
          else
            result = Result.new(
              reason: message.reload.provider_delivery_claimed? ?
                "delivery_already_in_flight" :
                "delivery_state_changed",
              context: {}
            )
          end
          next
        end
        if holds.empty? && !cancel_if_hold_released
          result = if message.claim_provider_delivery!(job_id: delivery_job_id)
            Result.new(reason: nil, context: {})
          else
            Result.new(reason: "delivery_state_changed", context: {})
          end
          next
        end

        if message.provider_delivery_claimed?
          result = Result.new(
            reason: "delivery_already_in_flight",
            context: {
              collection_hold_ids: holds.map(&:id),
              collection_hold_reasons: holds.map(&:reason).uniq
            }
          )
          next
        end

        cancelled = false
        message.with_lock do
          next unless payment_promise.follow_up_message_id == message.id
          next unless message.delivery_owned_by?(delivery_job_id)
          next if message.provider_delivery_claimed?

          message.update!(
            status: :failed,
            sent_at: nil,
            provider_message_id: nil,
            provider_thread_id: nil,
            failure_reason: "Promise follow-up was not sent because automated collection is paused.",
            delivery_uncertain: false
          )
          payment_promise.update!(follow_up_message: nil)
          cancelled = true
        end
        unless cancelled
          result = Result.new(reason: "delivery_state_changed", context: {})
          next
        end
        result = Result.new(
          reason: holds.any? ? "active_collection_hold" : "delivery_cancelled",
          context: {
            collection_hold_ids: holds.map(&:id),
            collection_hold_reasons: holds.map(&:reason).uniq
          }
        )
      end
    end
    result
  end
end

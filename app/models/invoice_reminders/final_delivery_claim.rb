class InvoiceReminders::FinalDeliveryClaim
  Result = Data.define(:reason, :context) do
    def claimed?
      reason.nil?
    end
  end

  def self.call(invoice:, reminder:, delivery_job_id:)
    result = nil
    Receivables::AccountLock.synchronize(account: invoice.account) do
      invoice.with_lock do
        message = reminder.conversation_message.reload
        unless message.delivery_owned_by?(delivery_job_id)
          result = Result.new(
            reason: "delivery_state_changed",
            context: {}
          )
          next
        end

        holds = invoice.active_collection_holds.reorder(:id).to_a
        if holds.empty?
          result = if message.claim_provider_delivery!(job_id: delivery_job_id)
            Result.new(reason: nil, context: {})
          else
            Result.new(reason: "delivery_state_changed", context: {})
          end
          next
        end

        stage = reminder.invoice_schedule ||
          invoice.account.invoice_schedules.find_by(
            category: reminder.category,
            day_offset: reminder.day_offset,
            kind: invoice.customer.payer_segment
          )
        InvoiceReminderSuppression.record_for!(
          invoice:,
          stage:,
          reason: :active_collection_hold
        ) if stage && !invoice.invoice_reminder_suppressions.for_stage(stage).exists?
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
        message.mark_delivery_failed!(
          job_id: delivery_job_id,
          failure_reason: "Reminder was not sent because automated collection is paused."
        )
        result = Result.new(
          reason: "active_collection_hold",
          context: {
            collection_hold_ids: holds.map(&:id),
            collection_hold_reasons: holds.map(&:reason).uniq
          }
        )
      end
    end
    result
  rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique
    Result.new(
      reason: "delivery_state_changed",
      context: {}
    )
  end
end

class ConversationMessages::ReconcilePendingDeliveriesJob < ApplicationJob
  include Sentry::Cron::MonitorCheckIns

  STALE_AFTER = 2.hours
  FAILURE_REASON = "Delivery confirmation timed out."

  queue_as :default

  sentry_monitor_check_ins(
    slug: "reconcile-pending-conversation-messages",
    monitor_config: Sentry::Cron::MonitorConfig.from_interval(
      1,
      :hour,
      checkin_margin: 10,
      max_runtime: 30
    )
  )

  def perform
    cutoff = STALE_AFTER.ago
    reconciled_count = 0

    ConversationMessage.stale_pending_deliveries(before: cutoff).find_each do |message|
      manual_reply = message.kind_manual_reply?
      delivery_was_claimed = message.provider_delivery_claimed?
      attempted_manual_reply = manual_reply && message.delivery_attempted_at.present?
      failure_reason = if delivery_was_claimed || attempted_manual_reply
        ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON
      else
        FAILURE_REASON
      end
      next unless message.reconcile_stale_delivery!(
        before: cutoff,
        failure_reason:,
        delivery_uncertain: delivery_was_claimed || attempted_manual_reply
      )

      reconciled_count += 1
      if manual_reply
        ConversationMessages::ManualReplyOutcome.finalize!(message)
      end
    end

    ConversationMessages::ManualReplyOutcome
      .needing_finalization
      .find_each do |message|
        ConversationMessages::ManualReplyOutcome.finalize!(message)
      end

    Rails.logger.warn(
      "conversation_message.pending_deliveries_reconciled " \
        "cutoff=#{cutoff.iso8601} count=#{reconciled_count}"
    ) if reconciled_count.positive?
  end
end

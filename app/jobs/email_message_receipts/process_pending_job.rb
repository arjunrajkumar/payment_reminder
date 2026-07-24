class EmailMessageReceipts::ProcessPendingJob < ApplicationJob
  include Sentry::Cron::MonitorCheckIns

  STALE_AFTER = 30.minutes

  queue_as :default

  sentry_monitor_check_ins(
    slug: "process-pending-gmail-receipts",
    monitor_config: Sentry::Cron::MonitorConfig.from_interval(
      15,
      :minute,
      checkin_margin: 5,
      max_runtime: 10
    )
  )

  def perform
    EmailMessageReceipt.unfinished_post_processing.find_each do |receipt|
      EmailMessageReceipts::ProcessJob.enqueue_post_processing(receipt)
    rescue StandardError => error
      Rails.logger.error(
        "email.processed_receipt_enqueue_failed " \
          "receipt_id=#{receipt.id} error=#{error.class.name}"
      )
    end

    EmailMessageReceipt.stale_processing(before: STALE_AFTER.ago).find_each do |receipt|
      if receipt.current_mailbox?
        receipt.recover_stale_processing!(before: STALE_AFTER.ago)
      else
        receipt.retire_if_mailbox_replaced!
      end
    end

    EmailMessageReceipt.due_for_processing.find_each do |receipt|
      unless receipt.current_mailbox?
        receipt.retire_if_mailbox_replaced!
        next
      end

      if receipt.email_connection.inbound_ready?
        EmailMessageReceipts::ProcessJob.enqueue(receipt)
      end
    end
  end
end

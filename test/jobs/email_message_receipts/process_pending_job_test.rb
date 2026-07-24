require "test_helper"

class EmailMessageReceipts::ProcessPendingJobTest < ActiveJob::TestCase
  setup do
    @connection = email_connections(:paid_jar_gmail)
  end

  test "recovers stale claims and schedules pending and due failed receipts" do
    pending = create_receipt("pending")
    failed = create_receipt("failed")
    failed.claim!(job_id: "failed-job")
    failed.fail!(
      job_id: "failed-job",
      error: EmailConnection::Errors::TemporaryProviderError.new,
      retry_at: 1.minute.ago
    )
    stale = create_receipt("stale")
    stale.claim!(job_id: "stale-job", at: 1.hour.ago)
    ignored = create_receipt("ignored")
    ignored.claim!(job_id: "ignored-job")
    ignored.ignore!(job_id: "ignored-job", reason: :unrelated)
    terminal = create_receipt("terminal")
    terminal.claim!(job_id: "terminal-job")
    terminal.fail!(
      job_id: "terminal-job",
      error: EmailConnection::Errors::PermanentProviderError.new,
      retry_at: nil
    )

    assert_enqueued_jobs 3, only: EmailMessageReceipts::ProcessJob do
      EmailMessageReceipts::ProcessPendingJob.perform_now
    end

    assert_predicate stale.reload, :status_pending?
    assert_predicate ignored.reload, :status_ignored?
    assert_predicate terminal.reload, :status_failed?
    scheduled_receipt_ids = enqueued_jobs.filter_map do |job|
      job.fetch(:args).first if job.fetch(:job) == EmailMessageReceipts::ProcessJob
    end
    assert_equal [ failed.id, pending.id, stale.id ].sort, scheduled_receipt_ids.sort

    clear_enqueued_jobs
    assert_no_enqueued_jobs only: EmailMessageReceipts::ProcessJob do
      EmailMessageReceipts::ProcessPendingJob.perform_now
    end
  end

  test "retires pending and stale work from a replaced mailbox identity" do
    pending = create_receipt("replaced-pending")
    stale = create_receipt("replaced-stale")
    stale.claim!(job_id: "old-worker", at: 1.hour.ago)
    @connection.update_column(:provider_account_id, "replacement-google-account")

    assert_no_enqueued_jobs only: EmailMessageReceipts::ProcessJob do
      EmailMessageReceipts::ProcessPendingJob.perform_now
    end

    [ pending, stale ].each do |receipt|
      assert_predicate receipt.reload, :status_ignored?
      assert_equal "mailbox_replaced", receipt.metadata.fetch("reason")
    end
  end

  test "schedules unfinished processed finalization after mailbox replacement" do
    processed = create_receipt("processed-finalization")
    message = invoices(:xero_invoice).conversation_messages.create!(
      account: @connection.account,
      conversation: Conversation.for_invoice!(
        invoice: invoices(:xero_invoice)
      ),
      direction: :outbound,
      kind: :scheduled_reminder,
      status: :sent,
      sent_at: Time.current,
      provider_message_id: "processed-finalization-provider"
    )
    processed.update_columns(
      status: "processed",
      conversation_message_id: message.id,
      direction: "outbound",
      processed_at: Time.current,
      post_processing_finalized_at: nil
    )
    @connection.update_column(
      :provider_account_id,
      "replacement-finalization-provider"
    )

    assert_enqueued_jobs 1, only: EmailMessageReceipts::ProcessJob do
      2.times { EmailMessageReceipts::ProcessPendingJob.perform_now }
    end
    scheduled = enqueued_jobs.sole
    assert_equal [
      processed.id,
      processed.provider_account_id,
      processed.email_connection_generation
    ], scheduled.fetch(:args)
    assert_equal scheduled.fetch("job_id"),
      processed.reload.post_processing_enqueued_job_id
    assert processed.post_processing_enqueued_at
  end

  private
    def create_receipt(suffix)
      @connection.email_message_receipts.create!(
        account: @connection.account,
        provider_message_id: "gmail-#{suffix}",
        discovered_at: Time.current
      )
    end
end

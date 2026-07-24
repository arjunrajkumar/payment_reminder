require "test_helper"

class EmailMessageReceipts::ProcessJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @connection = email_connections(:paid_jar_gmail)
    @receipt = @connection.email_message_receipts.create!(
      account: @connection.account,
      provider_message_id: "gmail-process-job",
      discovered_at: Time.current
    )
  end

  test "marks a deleted Gmail message ignored" do
    EmailMessageReceipts::Processor.stubs(:call)
      .raises(EmailConnection::Errors::MessageNotFound, "gone")

    perform_receipt

    assert_predicate @receipt.reload, :status_ignored?
    assert_equal "deleted_before_fetch", @receipt.metadata.fetch("reason")
  end

  test "enqueue reserves the receipt and suppresses duplicate queued jobs" do
    assert_enqueued_jobs 1, only: EmailMessageReceipts::ProcessJob do
      assert EmailMessageReceipts::ProcessJob.enqueue(@receipt)
      assert_not EmailMessageReceipts::ProcessJob.enqueue(@receipt)
    end

    assert @receipt.reload.processing_enqueued_job_id
    assert @receipt.processing_enqueued_at
  end

  test "an enqueue failure releases the receipt reservation" do
    ActiveJob::Base.queue_adapter.stubs(:enqueue).raises(RuntimeError, "queue unavailable")

    assert_raises RuntimeError do
      EmailMessageReceipts::ProcessJob.enqueue(@receipt)
    end

    assert_nil @receipt.reload.processing_enqueued_job_id
    assert_nil @receipt.processing_enqueued_at
  end

  test "a retry enqueue failure releases the receipt reservation" do
    EmailMessageReceipts::Processor.stubs(:call)
      .raises(EmailConnection::Errors::TemporaryProviderError, "rate limited")
    ActiveJob::Base.queue_adapter.stubs(:enqueue_at).raises(RuntimeError, "queue unavailable")

    assert_raises RuntimeError do
      perform_receipt
    end

    assert_predicate @receipt.reload, :status_failed?
    assert_nil @receipt.processing_enqueued_job_id
    assert_nil @receipt.processing_enqueued_at
  end

  test "mailbox thread lock contention leaves a retryable receipt" do
    EmailMessageReceipts::Processor.stubs(:call)
      .raises(EmailConnection::MailboxThreadLock::Unavailable, "lock busy")

    assert_enqueued_with(
      job: EmailMessageReceipts::ProcessJob,
      args: receipt_job_args(@receipt)
    ) do
      perform_receipt
    end

    assert_predicate @receipt.reload, :status_failed?
    assert_operator @receipt.next_retry_at, :<=, Time.current
    assert_equal EmailConnection::MailboxThreadLock::Unavailable.name,
      @receipt.last_error
  end

  test "retires a receipt from a replaced mailbox before processing" do
    @connection.update_column(:provider_account_id, "replacement-google-account")
    EmailMessageReceipts::Processor.expects(:call).never

    perform_receipt

    assert_predicate @receipt.reload, :status_ignored?
    assert_equal "mailbox_replaced", @receipt.metadata.fetch("reason")
  end

  test "a processed scheduled reminder finalizes after credential replacement without Gmail access" do
    reminder = create_sent_reminder
    subscribe_to_reminders
    link_processed_receipt(reminder.conversation_message)
    @connection.increment!(:credential_generation)
    EmailMessageReceipts::Processor.expects(:call).never

    assert_emails 1 do
      perform_receipt
    end

    assert @receipt.reload.post_processing_finalized_at
    assert_predicate reminder.notification_deliveries.sole,
      :status_delivered?
    assert_predicate ConversationEvent
      .kind_invoice_reminder_notifications_finalized.sole, :persisted?
  end

  test "a processed manual reply finalizes after provider replacement exactly once" do
    message = create_sent_manual_reply
    link_processed_receipt(message)
    @connection.update_column(
      :provider_account_id,
      "replacement-provider-account"
    )
    EmailMessageReceipts::Processor.expects(:call).never

    2.times { perform_receipt }

    assert @receipt.reload.post_processing_finalized_at
    assert_equal 1, message.conversation.conversation_events
      .kind_conversation_manual_reply_sent.count
    assert_nil message.conversation.reload.attention_required_at
  end

  test "a completed processed receipt makes every later job a no-op" do
    message = create_sent_manual_reply
    link_processed_receipt(message)
    @receipt.update!(post_processing_finalized_at: Time.current)
    ConversationMessages::EmailRecorder
      .expects(:finalize_existing_delivery!)
      .never

    2.times { perform_receipt }

    assert @receipt.reload.post_processing_finalized_at
  end

  test "a processed finalization failure stays retry-owned and sweep-discoverable" do
    reminder = create_sent_reminder
    link_processed_receipt(reminder.conversation_message)
    EmailMessageReceipts::Processor.expects(:call).never
    ConversationMessages::EmailRecorder
      .stubs(:finalize_existing_delivery!)
      .raises(StandardError, "finalization unavailable")

    assert_enqueued_with(
      job: EmailMessageReceipts::ProcessJob,
      args: receipt_job_args(@receipt)
    ) do
      perform_receipt
    end

    assert_nil @receipt.reload.post_processing_finalized_at
    assert @receipt.post_processing_enqueued_job_id
    assert_nil @receipt.post_processing_job_id
    clear_enqueued_jobs
    travel EmailMessageReceipt::POST_PROCESSING_STALE_AFTER + 1.second do
      assert_enqueued_with(
        job: EmailMessageReceipts::ProcessJob,
        args: receipt_job_args(@receipt)
      ) do
        EmailMessageReceipts::ProcessPendingJob.perform_now
      end
    end
  end

  test "finalization retry exhaustion releases ownership for the sweep" do
    reminder = create_sent_reminder
    link_processed_receipt(reminder.conversation_message)
    ConversationMessages::EmailRecorder
      .stubs(:finalize_existing_delivery!)
      .raises(StandardError, "finalization unavailable")
    job = EmailMessageReceipts::ProcessJob.new(*receipt_job_args(@receipt))
    job.exception_executions[
      [
        EmailMessageReceipts::ProcessJob::ProcessedFinalizationError
      ].to_s
    ] = 4

    job.perform_now

    assert_nil @receipt.reload.post_processing_finalized_at
    assert_nil @receipt.post_processing_enqueued_job_id
    assert_nil @receipt.post_processing_job_id
    clear_enqueued_jobs
    assert_enqueued_jobs 1, only: EmailMessageReceipts::ProcessJob do
      EmailMessageReceipts::ProcessPendingJob.perform_now
    end
  end

  test "an old-generation job cannot claim or clear requeued same-mailbox work" do
    old_arguments = receipt_job_args(@receipt)
    @connection.connect_gmail!(
      email: @connection.connected_email,
      name: @connection.provider_display_name,
      provider_account_id: @connection.provider_account_id,
      history_id: @connection.inbound_cursor,
      access_token: "replacement-access-token",
      refresh_token: "replacement-refresh-token",
      expires_at: 1.hour.from_now,
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )
    assert_predicate @receipt.reload, :status_pending?
    assert EmailMessageReceipts::ProcessJob.enqueue(@receipt)
    replacement_job_id = @receipt.reload.processing_enqueued_job_id
    EmailMessageReceipts::Processor.expects(:call).never

    EmailMessageReceipts::ProcessJob.perform_now(*old_arguments)

    assert_predicate @receipt.reload, :status_pending?
    assert_equal replacement_job_id, @receipt.processing_enqueued_job_id
    assert_equal @connection.credential_generation, @receipt.email_connection_generation
  end

  test "a canonical thread message reconsiders an earlier unrelated receipt" do
    invoice = invoices(:xero_invoice)
    conversation = Conversation.for_invoice!(invoice:)
    canonical_message = conversation.conversation_messages.create!(
      account: invoice.account,
      invoice:,
      email_connection: @connection,
      email_connection_generation: @connection.credential_generation,
      provider_account_id: @connection.provider_account_id,
      direction: :outbound,
      kind: :manual_reminder,
      status: :sent,
      sent_at: Time.current,
      provider_message_id: "canonical-thread-message",
      provider_thread_id: "reconsider-thread",
      from_address: @connection.connected_email,
      to_addresses: [ invoice.customer.email ],
      cc_addresses: [],
      subject: "Invoice #{invoice.number}",
      body: "Please pay"
    )
    ignored = @connection.email_message_receipts.create!(
      account: @connection.account,
      provider_message_id: "unknown-first",
      provider_thread_id: "reconsider-thread",
      discovered_at: Time.current
    )
    ignored.claim!(job_id: "ignore-job")
    ignored.ignore!(
      job_id: "ignore-job",
      reason: :unrelated,
      direction: :inbound,
      provider_thread_id: "reconsider-thread"
    )
    @receipt.update!(provider_thread_id: "reconsider-thread")
    assert ignored.reconsider_unrelated!
    EmailMessageReceipts::Processor.stubs(:call).returns(canonical_message)

    assert_enqueued_with(
      job: EmailMessageReceipts::ProcessJob,
      args: receipt_job_args(ignored)
    ) do
      perform_receipt
    end

    assert_predicate ignored.reload, :status_pending?
    assert ignored.processing_enqueued_job_id
  end

  test "records a temporary failure and retries only this receipt" do
    EmailMessageReceipts::Processor.stubs(:call)
      .raises(EmailConnection::Errors::TemporaryProviderError, "rate limited")

    assert_enqueued_with(
      job: EmailMessageReceipts::ProcessJob,
      args: receipt_job_args(@receipt)
    ) do
      perform_receipt
    end

    assert_predicate @receipt.reload, :status_failed?
    assert_operator @receipt.next_retry_at, :<=, Time.current
    assert_equal EmailConnection::Errors::TemporaryProviderError.name, @receipt.last_error
    assert @receipt.processing_enqueued_job_id
    assert @receipt.processing_enqueued_at
  end

  test "retries a database deadlock instead of stranding the receipt" do
    EmailMessageReceipts::Processor.stubs(:call)
      .raises(ActiveRecord::Deadlocked, "deadlock")

    assert_enqueued_with(
      job: EmailMessageReceipts::ProcessJob,
      args: receipt_job_args(@receipt)
    ) do
      perform_receipt
    end

    assert_predicate @receipt.reload, :status_failed?
    assert_operator @receipt.next_retry_at, :<=, Time.current
    assert_equal ActiveRecord::Deadlocked.name, @receipt.last_error
    assert @receipt.processing_enqueued_job_id
  end

  test "returns an owned claim to retryable state when credentials become unavailable" do
    EmailMessageReceipts::Processor.stubs(:call)
      .raises(EmailConnection::Errors::CredentialChanged, "credentials changed")

    perform_receipt

    assert_predicate @receipt.reload, :status_failed?
    assert_operator @receipt.next_retry_at, :<=, Time.current
    assert_equal EmailConnection::Errors::CredentialChanged.name, @receipt.last_error
    assert_nil @receipt.processing_job_id
  end

  test "keeps a receipt due after a network timeout refreshing OAuth" do
    @connection.update!(token_expires_at: 1.minute.ago)
    token_uri = EmailConnection::Gmail::Configuration.new.token_uri.to_s
    stub_request(:post, token_uri).to_timeout

    assert_enqueued_with(
      job: EmailMessageReceipts::ProcessJob,
      args: receipt_job_args(@receipt)
    ) do
      perform_receipt
    end

    assert_predicate @connection.reload, :active?
    assert_predicate @receipt.reload, :status_failed?
    assert_operator @receipt.next_retry_at, :<=, Time.current
    assert_equal EmailConnection::Errors::TemporaryProviderError.name, @receipt.last_error
  end

  test "leaves an authentication failure recoverable after reconnection" do
    error = EmailConnection::Errors::AuthenticationError.new("revoked")
    EmailMessageReceipts::Processor.stubs(:call).raises(error)

    assert_raises EmailConnection::Errors::AuthenticationError do
      perform_receipt
    end

    assert_predicate @receipt.reload, :status_failed?
    assert_operator @receipt.next_retry_at, :>, Time.current
  end

  test "marks the connection errored when OAuth refresh is revoked" do
    @connection.update!(token_expires_at: 1.minute.ago)
    token_uri = EmailConnection::Gmail::Configuration.new.token_uri.to_s
    stub_request(:post, token_uri).to_return(
      status: 400,
      body: { error: "invalid_grant" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    assert_raises EmailConnection::Errors::AuthenticationError do
      perform_receipt
    end

    assert_predicate @connection.reload, :errored?
    assert_predicate @receipt.reload, :status_failed?
    assert_operator @receipt.next_retry_at, :>, Time.current
    assert_equal EmailConnection::Errors::AuthenticationError.name, @receipt.last_error
  end

  test "records and re-raises an unexpected processing failure" do
    error = NoMethodError.new("private message content")
    EmailMessageReceipts::Processor.stubs(:call).raises(error)

    raised = assert_raises EmailMessageReceipts::ProcessJob::UnexpectedProcessingError do
      perform_receipt
    end

    assert_instance_of EmailMessageReceipts::ProcessJob::UnexpectedProcessingError, raised
    assert_equal NoMethodError.name, raised.message
    assert_not_includes raised.message, "private message content"
    assert_nil raised.cause
    assert_predicate @receipt.reload, :status_failed?
    assert_nil @receipt.next_retry_at
    assert_equal NoMethodError.name, @receipt.last_error
  end

  test "sanitizes unexpected exceptions with non-string constructors" do
    error = ActiveRecord::RecordInvalid.new(@receipt)
    EmailMessageReceipts::Processor.stubs(:call).raises(error)

    raised = assert_raises EmailMessageReceipts::ProcessJob::UnexpectedProcessingError do
      perform_receipt
    end

    assert_equal ActiveRecord::RecordInvalid.name, raised.message
    assert_nil raised.cause
    assert_predicate @receipt.reload, :status_failed?
    assert_equal ActiveRecord::RecordInvalid.name, @receipt.last_error
  end

  test "keeps a known permanent provider rejection terminal" do
    error = EmailConnection::Errors::PermanentProviderError.new("private provider rejection")
    EmailMessageReceipts::Processor.stubs(:call).raises(error)

    assert_no_enqueued_jobs only: EmailMessageReceipts::ProcessJob do
      perform_receipt
    end

    assert_predicate @receipt.reload, :status_failed?
    assert_nil @receipt.next_retry_at
    assert_equal EmailConnection::Errors::PermanentProviderError.name, @receipt.last_error
  end

  test "stops automatically retrying a temporary failure at the receipt attempt limit" do
    @receipt.update!(attempts: EmailMessageReceipts::ProcessJob::MAX_ATTEMPTS - 1)
    EmailMessageReceipts::Processor.stubs(:call)
      .raises(EmailConnection::Errors::TemporaryProviderError, "private temporary failure")

    assert_no_enqueued_jobs only: EmailMessageReceipts::ProcessJob do
      perform_receipt
    end

    assert_predicate @receipt.reload, :status_failed?
    assert_equal EmailMessageReceipts::ProcessJob::MAX_ATTEMPTS, @receipt.attempts
    assert_nil @receipt.next_retry_at
    assert_equal EmailConnection::Errors::TemporaryProviderError.name, @receipt.last_error
  end

  private
    def perform_receipt(receipt = @receipt)
      EmailMessageReceipts::ProcessJob.perform_now(*receipt_job_args(receipt))
    end

    def receipt_job_args(receipt)
      [
        receipt.id,
        receipt.provider_account_id,
        receipt.email_connection_generation
      ]
    end

    def link_processed_receipt(message)
      @receipt.update_columns(
        status: "processed",
        conversation_message_id: message.id,
        direction: message.direction,
        processed_at: Time.current,
        post_processing_finalized_at: nil
      )
    end

    def subscribe_to_reminders
      identity = Identity.create!(
        email_address: "processed-receipt-notification@example.com"
      )
      user = @connection.account.users.create!(
        name: "Processed receipt notification",
        identity:,
        verified_at: Time.current
      )
      user.notification_subscriptions.create!(
        event: :invoice_reminder,
        email: true
      )
    end

    def create_sent_reminder
      invoice = invoices(:xero_invoice)
      message = invoice.conversation_messages.create!(
        account: invoice.account,
        invoice:,
        conversation: Conversation.for_invoice!(invoice:),
        direction: :outbound,
        kind: :scheduled_reminder,
        status: :sent,
        sent_at: Time.current
      )
      invoice.invoice_reminders.create!(
        account: invoice.account,
        conversation_message: message,
        category: :pre_due,
        day_offset: 7,
        stage_key: "pre_due_7",
        tone: :friendly,
        terminal_at_delivery: false
      )
    end

    def create_sent_manual_reply
      invoice = invoices(:xero_invoice)
      conversation = Conversation.for_invoice!(invoice:)
      anchor = conversation.conversation_messages.create!(
        account: invoice.account,
        invoice:,
        email_connection: @connection,
        email_connection_generation: @connection.credential_generation,
        provider_account_id: @connection.provider_account_id,
        provider_message_id: "processed-manual-reply-anchor",
        provider_thread_id: "processed-manual-reply-thread",
        internet_message_id: "<processed-manual-reply-anchor@example.com>",
        conversation:,
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.current,
        from_address: invoice.customer.email
      )
      conversation.update!(attention_required_at: anchor.received_at)
      target = ConversationMessages::ManualReply.reply_target_for(
        conversation:,
        reply_to_message: anchor
      )
      message = ConversationMessages::ManualReply.enqueue!(
        conversation:,
        reply_to_message: anchor,
        actor_user: users(:arjun),
        body: "Already sent.",
        idempotency_key: "processed-manual-reply",
        composer_token: ConversationMessages::ManualReply.composer_token_for(
          conversation:,
          target:
        )
      )
      message.update_columns(
        direction: :outbound,
        status: :sent,
        sent_at: Time.current,
        provider_message_id: "processed-manual-reply-provider",
        provider_thread_id: anchor.provider_thread_id
      )
      message
    end
end

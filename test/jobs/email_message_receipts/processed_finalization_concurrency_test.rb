require "test_helper"
require "timeout"

class EmailMessageReceipts::ProcessedFinalizationConcurrencyTest <
    ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @account_id, @receipt_id, @message_id = Thread.new do
      create_records
    end.value
  end

  teardown do
    account_id = @account_id
    Thread.new { Account.find_by(id: account_id)&.destroy! }.value
  end

  test "concurrent duplicate jobs invoke the processed finalizer once" do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    ConversationMessages::EmailRecorder
      .expects(:finalize_existing_delivery!)
      .with { _1.id == @message_id }
      .once
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          receipt = EmailMessageReceipt.find(@receipt_id)
          EmailMessageReceipts::ProcessJob.perform_now(
            receipt.id,
            receipt.provider_account_id,
            receipt.email_connection_generation
          )
          results << :completed
        end
      rescue Exception => error # rubocop:disable Lint/RescueException
        results << error
      ensure
        # rubocop:enable Lint/RescueException
      end
    end
    2.times { Timeout.timeout(2) { ready.pop } }
    2.times { start << true }
    values = 2.times.map { Timeout.timeout(5) { results.pop } }
    threads.each { |thread| Timeout.timeout(5) { thread.join } }

    assert_empty values.grep(Exception)
    assert EmailMessageReceipt.find(@receipt_id)
      .post_processing_finalized_at
  end

  private
    def create_records
      account = Account.create!(
        name: "Processed finalization #{SecureRandom.uuid}"
      )
      connection = account.create_email_connection!(
        provider: :gmail,
        status: :active,
        provider_account_id: "processed-finalization-#{SecureRandom.uuid}",
        connected_email: "processed-finalization@example.com",
        access_token: "processed-finalization-access",
        refresh_token: "processed-finalization-refresh",
        token_expires_at: 1.year.from_now,
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
      )
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: SecureRandom.uuid
      )
      customer = source.customers.create!(
        account:,
        external_id: SecureRandom.uuid,
        name: "Processed finalization customer"
      )
      invoice = source.invoices.create!(
        account:,
        customer:,
        external_id: SecureRandom.uuid,
        status: :open,
        amount_due: 100
      )
      message = invoice.conversation_messages.create!(
        account:,
        invoice:,
        conversation: Conversation.for_invoice!(invoice:),
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "processed-message-#{SecureRandom.uuid}",
        direction: :outbound,
        kind: :scheduled_reminder,
        status: :sent,
        sent_at: Time.current
      )
      receipt = connection.email_message_receipts.create!(
        account:,
        provider_message_id: "processed-receipt-#{SecureRandom.uuid}",
        discovered_at: Time.current
      )
      receipt.update_columns(
        status: "processed",
        conversation_message_id: message.id,
        direction: "outbound",
        processed_at: Time.current,
        post_processing_finalized_at: nil
      )
      [ account.id, receipt.id, message.id ]
    end
end

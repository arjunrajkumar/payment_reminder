require "set"

class EmailMessageReceipts::Processor
  def self.call(
    receipt,
    job_id:,
    mailbox: EmailConnection::Gmail::Mailbox.new(
      connection: receipt.email_connection,
      provider_account_id: receipt.provider_account_id,
      credential_generation: receipt.email_connection_generation
    )
  )
    new(receipt, job_id:, mailbox:).call
  end

  def initialize(receipt, job_id:, mailbox:)
    @receipt = receipt
    @job_id = job_id
    @mailbox = mailbox
  end

  def call
    verify_claim!
    if existing = existing_provider_message
      return EmailConnection::MailboxThreadLock.synchronize(
        account: receipt.account,
        provider_account_id: receipt.provider_account_id,
        provider_thread_id: existing.provider_thread_id
      ) do
        verify_claim!
        ConversationMessages::EmailRecorder.link_existing(
          receipt:,
          existing:,
          job_id:
        )
      end
    end

    gmail_message = mailbox.message(id: receipt.provider_message_id)
    verify_claim!
    parsed_message = EmailConnection::Gmail::MessageParser.call(gmail_message)
    EmailConnection::MailboxThreadLock.synchronize(
      account: receipt.account,
      provider_account_id: receipt.provider_account_id,
      provider_thread_id: parsed_message.provider_thread_id
    ) do
      process(parsed_message)
    end
  end

  private
    attr_reader :receipt, :job_id, :mailbox

    def process(parsed_message)
      verify_claim!
      if existing = existing_provider_message
        return ConversationMessages::EmailRecorder.link_existing(
          receipt:,
          existing:,
          job_id:
        )
      end

      direction, ignored_reason = direction_and_ignored_reason(parsed_message.label_ids)
      if ignored_reason
        return receipt.ignore!(
          job_id:,
          reason: ignored_reason,
          direction:,
          provider_thread_id: parsed_message.provider_thread_id
        )
      end

      if ConversationMessages::EmailRecorder.app_created_delivery_for(
        account: receipt.account,
        parsed_message:,
        direction:,
        provider_account_id: receipt.provider_account_id
      )
        return ConversationMessages::EmailRecorder.call(
          account: receipt.account,
          receipt:,
          parsed_message:,
          direction:,
          match: nil,
          job_id:,
          provider_account_id: receipt.provider_account_id
        )
      end

      match = ConversationMessages::EmailMatcher.call(
        account: receipt.account,
        provider_account_id: receipt.provider_account_id,
        parsed_message:,
        direction:
      )
      unless match.relevant?
        return receipt.ignore!(
          job_id:,
          reason: :unrelated,
          direction:,
          provider_thread_id: parsed_message.provider_thread_id
        )
      end

      ConversationMessages::EmailRecorder.call(
        account: receipt.account,
        receipt:,
        parsed_message:,
        direction:,
        match:,
        job_id:,
        provider_account_id: receipt.provider_account_id
      )
    end

    def verify_claim!
      return if receipt.processing_owned_by?(job_id) && receipt.current_mailbox?

      raise EmailMessageReceipt::ClaimLost
    end

    def existing_provider_message
      receipt.account.conversation_messages.find_by(
        provider_account_id: receipt.provider_account_id,
        provider_message_id: receipt.provider_message_id
      )
    end

    def direction_and_ignored_reason(label_ids)
      labels = label_ids.to_set
      return [ nil, :draft ] if labels.include?("DRAFT")
      return [ nil, :trash ] if labels.include?("TRASH")
      return [ "outbound", nil ] if labels.include?("SENT")

      [ "inbound", nil ]
    end
end

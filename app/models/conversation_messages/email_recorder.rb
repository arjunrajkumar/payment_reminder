class ConversationMessages::EmailRecorder
  def self.call(account:, receipt:, parsed_message:, direction:, match:, job_id:, provider_account_id:)
    new(
      account:,
      receipt:,
      parsed_message:,
      direction:,
      match:,
      job_id:,
      provider_account_id:
    ).call
  end

  def self.link_existing(receipt:, existing:, job_id:)
    record_link = lambda do
      receipt.with_processing_claim!(job_id:) do
        completed = receipt.complete!(
          job_id:,
          conversation_message: existing,
          direction: existing.direction,
          provider_thread_id: existing.provider_thread_id,
          metadata: { "existing_message" => true }
        )
        raise EmailMessageReceipt::ClaimLost unless completed
        receipt.reconsider_unrelated_thread_receipts!(anchor_message: existing)
      end
    end
    Receivables::AccountLock.synchronize(account: receipt.account) do
      if existing.invoice
        existing.invoice.with_lock(&record_link)
      else
        record_link.call
      end
    end
    finalize_existing_delivery!(existing)
    existing
  end

  def self.finalize_existing_delivery!(existing)
    return existing unless existing&.status_sent?

    if existing.kind_manual_reply?
      Conversations::Attention.clear_for_outbound!(existing)
      ConversationMessages::ManualReplyOutcome.finalize!(existing)
    elsif existing.kind_promise_follow_up?
      existing.payment_promise_follow_up&.confirm_imported_follow_up!(
        message: existing
      )
    elsif existing.kind_scheduled_reminder?
      reminder = existing.invoice_reminder
      InvoiceReminders::Notifier.deliver_once(
        invoice: existing.invoice,
        reminder:,
        terminal: reminder.terminal_stage?
      ) if reminder
    end
    existing
  end

  def self.app_created_delivery_for(
    account:,
    parsed_message:,
    direction:,
    provider_account_id:
  )
    return unless direction.to_s == "outbound"
    return if parsed_message.internet_message_id.blank?

    digest = Digest::SHA256.hexdigest(parsed_message.internet_message_id)
    account.conversation_messages
      .where(
        kind: %i[
          manual_reply
          manual_reminder
          scheduled_reminder
          promise_follow_up
        ]
      )
      .where(
        "requested_provider_account_id = :provider_account_id " \
          "OR provider_account_id = :provider_account_id",
        provider_account_id:
      )
      .where(internet_message_id_digest: digest)
      .find_by(internet_message_id: parsed_message.internet_message_id)
  end

  def initialize(account:, receipt:, parsed_message:, direction:, match:, job_id:, provider_account_id:)
    @account = account
    @receipt = receipt
    @message = parsed_message
    @direction = direction.to_s
    @match = match
    @job_id = job_id
    @provider_account_id = provider_account_id.to_s.strip.presence ||
      raise(ArgumentError, "provider_account_id is required")
  end

  def call
    record
  end

  private
    def record
      if existing = provider_messages.find_by(provider_message_id: message.provider_message_id)
        return self.class.link_existing(receipt:, existing:, job_id:)
      end
      if existing_delivery = app_created_delivery
        return reconcile_app_created_delivery(existing_delivery)
      end

      with_invoice_lock(matched_invoice) { record_new_message }
    rescue ActiveRecord::RecordNotUnique
      link_existing_winner
    end

    attr_reader :account,
      :receipt,
      :message,
      :direction,
      :match,
      :job_id,
      :provider_account_id

    def record_new_message
      recorded_message = nil
      receipt.with_processing_claim!(job_id:) do
        raise EmailMessageReceipt::ClaimLost unless receipt.provider_account_id == provider_account_id

        conversation = resolve_conversation
        recorded_message = conversation.conversation_messages.create!(message_attributes(conversation))
        record_event(recorded_message)
        Conversations::ReviewWorkUnit.reconcile_workflow_owner!(
          conversation: recorded_message.conversation
        )
        raise EmailMessageReceipt::ClaimLost unless complete_receipt!(recorded_message)
        receipt.reconsider_unrelated_thread_receipts!(anchor_message: recorded_message)

        apply_attention(recorded_message)
        reopen_confident_inbound(conversation)
      end
      recorded_message
    end

    def matched_invoice
      match.invoice || match.conversation&.invoice
    end

    def with_invoice_lock(invoice, &block)
      Receivables::AccountLock.synchronize(account:) do
        invoice ? invoice.with_lock(&block) : block.call
      end
    end

    def resolve_conversation
      conversation = if match.conversation
        match.conversation
      elsif match.invoice
        Conversation.for_invoice!(invoice: match.invoice)
      elsif match.customer
        account.conversations.create!(customer: match.customer)
      else
        account.conversations.create!
      end

      conversation.lock!
      enrich_conversation_customer!(conversation)
      conversation
    end

    def enrich_conversation_customer!(conversation)
      return if match.customer.blank? || conversation.customer == match.customer

      if conversation.customer.present?
        raise EmailConnection::Errors::TemporaryProviderError, "conversation_customer_changed"
      end

      conversation.update!(customer: match.customer)
      @conversation_customer_assigned = true
    end

    def message_attributes(conversation)
      inbound = direction == "inbound"
      {
        account:,
        invoice: conversation.invoice,
        email_connection: receipt.email_connection,
        email_connection_generation: receipt.email_connection_generation,
        provider_account_id:,
        direction:,
        kind: inbound ? :customer_email : :manual_email,
        status: inbound ? :received : :sent,
        received_at: inbound ? message.internal_date : nil,
        sent_at: inbound ? nil : message.internal_date,
        provider_message_id: message.provider_message_id,
        provider_thread_id: message.provider_thread_id,
        from_address: message.from_address,
        to_addresses: message.to_addresses,
        cc_addresses: message.cc_addresses,
        bcc_addresses: message.bcc_addresses,
        reply_to_addresses: message.reply_to_addresses,
        subject: message.subject,
        body: message.body,
        internet_message_id: message.internet_message_id,
        in_reply_to_message_ids: message.in_reply_to_message_ids,
        reference_message_ids: message.reference_message_ids,
        provider_metadata: {
          "label_ids" => message.label_ids,
          "parse_warnings" => message.parse_warnings
        },
        matching_status: match.matching_status,
        matching_method: match.matching_method,
        review_required: match.review_required,
        review_reasons: match.review_reasons,
        automatic: message.automatic
      }
    end

    def record_event(recorded_message)
      inbound = direction == "inbound"
      ConversationEvent.record!(
        conversation: recorded_message.conversation,
        conversation_message: recorded_message,
        kind: inbound ? :conversation_message_received : :conversation_message_imported,
        actor_kind: inbound ? :customer : :system,
        metadata: {
          "matching_status" => match.matching_status,
          "matching_method" => match.matching_method,
          "customer_id" => match.customer&.id,
          "invoice_id" => match.invoice&.id,
          "review_reasons" => match.review_reasons,
          "automatic" => message.automatic,
          "spam" => message.spam?,
          "import_direction" => direction,
          "conversation_customer_assigned" => conversation_customer_assigned?
        }.compact
      )
    end

    def reopen_confident_inbound(conversation)
      return unless direction == "inbound"
      return unless match.matching_status == "matched"
      return if match.review_required || message.automatic || message.spam?

      conversation.reopen! if conversation.status_resolved?
    end

    def complete_receipt!(conversation_message, existing: false)
      receipt.complete!(
        job_id:,
        conversation_message:,
        direction: conversation_message.direction,
        provider_thread_id: message.provider_thread_id.presence || conversation_message.provider_thread_id,
        metadata: existing ? { "existing_message" => true } : receipt_metadata(conversation_message)
      )
    end

    def link_existing_winner
      winner = provider_messages.find_by!(provider_message_id: message.provider_message_id)
      with_invoice_lock(winner.invoice) do
        receipt.with_processing_claim!(job_id:) do
          raise EmailMessageReceipt::ClaimLost unless receipt.provider_account_id == provider_account_id
          raise EmailMessageReceipt::ClaimLost unless complete_receipt!(winner, existing: true)
          receipt.reconsider_unrelated_thread_receipts!(anchor_message: winner)
        end
      end
      winner
    end

    def provider_messages
      account.conversation_messages.where(provider_account_id:)
    end

    def app_created_delivery
      self.class.app_created_delivery_for(
        account:,
        parsed_message: message,
        direction:,
        provider_account_id:
      )
    end

    def reconcile_app_created_delivery(existing)
      newly_confirmed = false

      with_invoice_lock(existing.invoice) do
        receipt.with_processing_claim!(job_id:) do
          raise EmailMessageReceipt::ClaimLost unless receipt.provider_account_id == provider_account_id

          newly_confirmed = !existing.status_sent? || existing.provider_message_id.blank?
          unless existing.reconcile_imported_app_delivery!(
            receipt:,
            parsed_message: message,
            provider_account_id:
          )
            raise EmailMessageReceipt::ClaimLost
          end
          if existing.kind_promise_follow_up?
            existing.payment_promise_follow_up&.confirm_imported_follow_up!(
              message: existing
            )
          end
          raise EmailMessageReceipt::ClaimLost unless complete_receipt!(existing)
          receipt.reconsider_unrelated_thread_receipts!(anchor_message: existing)
        end
      end

      if newly_confirmed
        finalize_reconciled_delivery(existing.reload)
      end
      existing
    end

    def finalize_reconciled_delivery(existing)
      if existing.kind_manual_reply?
        ConversationMessages::ManualReplyOutcome.finalize!(existing)
      elsif existing.kind_scheduled_reminder?
        reminder = existing.invoice_reminder
        InvoiceReminders::Notifier.deliver_once(
          invoice: existing.invoice,
          reminder:,
          terminal: reminder.terminal_stage?
        )
      end
    end

    def apply_attention(recorded_message)
      Conversations::Attention.require_for_message!(recorded_message)
      if recorded_message.direction_outbound? && !recorded_message.awaiting_review?
        Conversations::Attention.clear_for_outbound!(recorded_message)
      end
      Conversations::Attention.recompute!(
        conversation: recorded_message.conversation
      )
    end

    def conversation_customer_assigned?
      @conversation_customer_assigned == true
    end

    def receipt_metadata(conversation_message)
      return {
        "app_created_delivery_reconciled" => true,
        "delivery_kind" => conversation_message.kind
      } unless match

      {
        "matching_status" => match.matching_status,
        "matching_method" => match.matching_method
      }
    end
end

class Conversations::ManualMatcher
  class Error < StandardError; end
  class AlreadyLinked < Error; end
  class InvalidSelection < Error; end

  def self.call(
    source_conversation:,
    reviewed_message:,
    target_invoice: nil,
    target_customer: nil,
    actor_user:,
    work_unit_token:,
    at: Time.current
  )
    new(
      source_conversation:,
      reviewed_message:,
      target_invoice:,
      target_customer:,
      actor_user:,
      work_unit_token:,
      at:
    ).call
  end

  def initialize(
    source_conversation:,
    reviewed_message:,
    target_invoice:,
    target_customer:,
    actor_user:,
    work_unit_token:,
    at:
  )
    @source_conversation = source_conversation
    @reviewed_message = reviewed_message
    @target_invoice = target_invoice
    @target_customer = target_customer
    @actor_user = actor_user
    @work_unit_token = work_unit_token
    @at = at
  end

  def call
    validate_records!
    result = EmailConnection::MailboxThreadLock.synchronize(
      account:,
      provider_account_id: reviewed_message.provider_account_id,
      provider_thread_id: reviewed_message.provider_thread_id
    ) do
      validate_records!
      Receivables::AccountLock.synchronize(account:) do
        work_unit_conversation.with_lock do
          Conversations::WorkUnitSnapshot.verify!(
            token: work_unit_token,
            conversation: work_unit_conversation
          )
          Conversation.transaction(requires_new: true) do
            result = target_invoice ? link_to_invoice : assign_customer
            reconsider_related_receipts!
            result
          end
        end
      end
    end
    ConversationAi::EligibilityHook.for_conversation(result)
    result
  rescue EmailConnection::MailboxThreadLock::Unavailable
    raise Error, "This Gmail thread is being updated. Please try again."
  rescue Conversations::ReviewWorkUnit::SplitInvoiceWorkUnit
    raise InvalidSelection,
      "This Gmail thread is already linked to another invoice."
  end

  private
    attr_reader :source_conversation,
      :reviewed_message,
      :target_invoice,
      :target_customer,
      :actor_user,
      :work_unit_token,
      :at,
      :account

    def work_unit_conversation
      source_conversation.canonical
    end

    def validate_records!
      @account = source_conversation.account
      records = [ reviewed_message, target_invoice, target_customer, actor_user ].compact
      unless account.present? && records.all? { |record| record.account_id == account.id }
        raise ActiveRecord::RecordNotFound
      end
      unless Conversations::ReviewWorkUnit.includes_message?(
        conversation: source_conversation,
        message: reviewed_message
      )
        raise ActiveRecord::RecordNotFound
      end
      if target_invoice.nil? && target_customer.nil?
        raise InvalidSelection, "Choose an invoice or customer."
      end
    end

    def link_to_invoice
      result = nil

      Conversation.transaction do
        @target_invoice = account.invoices.lock.find(target_invoice.id)
        @target_customer = target_invoice.customer
        requested_owner = account.conversations.find(source_conversation.id).canonical
        if requested_owner.invoice_id.present? &&
            requested_owner.invoice_id != target_invoice.id
          raise AlreadyLinked,
            "This thread is already linked to another invoice."
        end
        existing_owner_ids = Conversations::ReviewWorkUnit
          .invoice_owner_ids_for(message: reviewed_message)
        existing_owners = account.conversations
          .where(id: existing_owner_ids)
          .order(:id)
          .lock
          .to_a
        if existing_owners.any? { |owner| owner.invoice_id != target_invoice.id }
          raise InvalidSelection,
            "This Gmail thread is already linked to another invoice."
        end
        target = Conversation.for_invoice!(invoice: target_invoice)
        source_ids = covered_source_ids
        locked = account.conversations
          .where(id: (source_ids + [ target.id ]).uniq)
          .order(:id)
          .lock
          .index_by(&:id)
        locked_target = locked.fetch(target.id)
        sources = source_ids.map { |id| locked.fetch(id) }
        validate_link_targets!(sources, locked_target)

        covered_messages = lock_covered_messages(sources)
        actions, escalations = lock_workflow_records(sources)
        already_applied = sources.all? do |source|
          source.canonical_conversation_id == locked_target.id
        end && covered_messages.all? do |message|
          message.invoice_id == target_invoice.id && review_complete?(message)
        end
        if already_applied
          result = locked_target
          next
        end

        sources.each do |source|
          next if source.canonical_conversation_id == locked_target.id

          source.update!(
            canonical_conversation: locked_target,
            attention_required_at: nil
          )
        end
        review_and_assign_invoice!(covered_messages)
        transfer_workflow_records!(
          actions:,
          escalations:,
          target: locked_target,
          validated_message_ids: covered_messages.map(&:id)
        )
        transfer_attention!(sources, locked_target)
        record_link_events!(sources, locked_target, covered_messages)
        result = locked_target
      end

      result
    end

    def assign_customer
      sources = nil
      covered_messages = nil

      Conversation.transaction do
        @target_customer = account.customers.lock.find(target_customer.id)
        sources = account.conversations
          .where(id: covered_source_ids)
          .order(:id)
          .lock
          .to_a
        if sources.any? { |source| source.canonical_conversation_id.present? || source.invoice_id.present? }
          raise AlreadyLinked, "This thread is already linked to an invoice."
        end
        if sources.any? { |source| source.customer_id.present? && source.customer_id != target_customer.id }
          raise InvalidSelection, "This thread is already assigned to another customer."
        end

        covered_messages = lock_covered_messages(sources)
        already_applied = sources.all? { |source| source.customer_id == target_customer.id } &&
          covered_messages.all? { |message| review_complete?(message) }
        next if already_applied

        sources.each { |source| source.update!(customer: target_customer) }
        review_messages!(covered_messages)
        record_customer_assignment_events!(sources, covered_messages)
        sources.each do |source|
          Conversations::Attention.recompute!(conversation: source)
        end
      end

      source_conversation.reload
    end

    def covered_source_ids
      Conversations::ReviewWorkUnit.source_conversation_ids_for(
        message: reviewed_message
      )
    end

    def lock_covered_messages(sources)
      Conversations::ReviewWorkUnit
        .message_scope_for(message: reviewed_message)
        .where(conversation_id: sources.map(&:id))
        .order(:id)
        .lock
        .to_a
    end

    def lock_workflow_records(sources)
      source_ids = sources.map(&:id)
      actions = account.conversation_actions
        .where(conversation_id: source_ids)
        .order(:id)
        .lock
        .to_a
      escalations = account.conversation_escalations
        .where(conversation_id: source_ids)
        .order(:id)
        .lock
        .to_a
      [ actions, escalations ]
    end

    def validate_link_targets!(sources, target)
      sources.each do |source|
        if source.invoice_id.present?
          raise AlreadyLinked, "An invoice conversation cannot be linked as a source."
        end
        next if source.canonical_conversation_id.nil? ||
          source.canonical_conversation_id == target.id

        raise AlreadyLinked, "This thread is already linked to another invoice."
      end
      if sources.any? do |source|
          source.customer_id.present? && source.customer_id != target_customer.id
        end
        raise InvalidSelection, "This thread is already assigned to another customer."
      end
    end

    def review_and_assign_invoice!(messages)
      messages.each do |message|
        message.update!(invoice: target_invoice)
        complete_manual_review!(message)
      end
    end

    def review_messages!(messages)
      messages.each do |message|
        complete_manual_review!(message)
      end
    end

    def complete_manual_review!(message)
      return unless message.review_required?

      if message.reviewed_at.nil?
        message.update!(
          reviewed_at: at,
          reviewed_by_user: actor_user,
          review_outcome: :manual_match
        )
      elsif message.review_outcome_no_match_needed?
        message.correct_review_to_manual_match!(
          actor_user:,
          at:
        )
      end
    end

    def transfer_attention!(sources, target)
      sources.each do |source|
        source.update!(attention_required_at: nil) if source.attention_required_at.present?
      end
      Conversations::Attention.recompute!(conversation: target)
    end

    def transfer_workflow_records!(
      actions:,
      escalations:,
      target:,
      validated_message_ids:
    )
      actions.each do |action|
        action.send(
          :transfer_to_conversation!,
          target,
          validated_message_ids:
        )
      end
      escalations.each do |escalation|
        escalation.send(
          :transfer_to_conversation!,
          target,
          validated_message_ids:
        )
      end
    end

    def record_link_events!(sources, target, messages)
      metadata = audit_metadata(sources, target, messages)
      sources.each do |source|
        ConversationEvent.record!(
          conversation: source,
          kind: :conversations_linked,
          actor_kind: :user,
          actor_user:,
          metadata:,
          created_at: at
        )
      end
      ConversationEvent.create!(
        account:,
        conversation: target,
        kind: :conversation_manually_matched,
        actor_kind: :user,
        actor_user:,
        metadata:,
        created_at: at
      )
    end

    def record_customer_assignment_events!(sources, messages)
      metadata = {
        "source_conversation_ids" => sources.map(&:id),
        "target_conversation_id" => nil,
        "invoice_id" => nil,
        "customer_id" => target_customer.id,
        "covered_message_ids" => messages.map(&:id),
        "original_matching_evidence" => original_evidence(messages)
      }
      sources.each do |source|
        ConversationEvent.create!(
          account:,
          conversation: source,
          kind: :conversation_manually_matched,
          actor_kind: :user,
          actor_user:,
          metadata:,
          created_at: at
        )
      end
    end

    def audit_metadata(sources, target, messages)
      {
        "source_conversation_ids" => sources.map(&:id),
        "original_customer_ids" => sources.index_with(&:customer_id),
        "target_conversation_id" => target.id,
        "invoice_id" => target_invoice.id,
        "customer_id" => target_customer.id,
        "covered_message_ids" => messages.map(&:id),
        "original_matching_evidence" => original_evidence(messages)
      }
    end

    def original_evidence(messages)
      messages.map do |message|
        {
          "message_id" => message.id,
          "matching_status" => message.matching_status,
          "matching_method" => message.matching_method,
          "review_reasons" => message.review_reasons
        }
      end
    end

    def review_complete?(message)
      !message.review_required? || message.review_outcome_manual_match?
    end

    def reconsider_related_receipts!
      return if reviewed_message.provider_thread_id.blank?
      return if reviewed_message.email_connection_id.blank?

      EmailMessageReceipt.where(
        email_connection_id: reviewed_message.email_connection_id,
        provider_account_id: reviewed_message.provider_account_id,
        provider_thread_id: reviewed_message.provider_thread_id,
        status: :ignored
      ).find_each do |receipt|
        next unless receipt.reconsider_unrelated!(
          generation: reviewed_message.email_connection_generation
        )

        EmailMessageReceipts::ProcessJob.enqueue(receipt)
      rescue StandardError => error
        Rails.logger.error(
          "email.manual_match_receipt_enqueue_failed " \
            "receipt_id=#{receipt.id} error=#{error.class.name}"
        )
      end
    end
end

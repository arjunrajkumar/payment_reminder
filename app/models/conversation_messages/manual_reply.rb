class ConversationMessages::ManualReply
  MAXIMUM_BODY_LENGTH = 10_000
  ReplyTarget = Data.define(:message, :recipient)

  class Error < StandardError; end
  class UnsafeAnchor < Error; end
  class StaleComposer < Error; end
  class DeliveryUnavailable < Error; end
  class IdempotencyConflict < Error; end

  class << self
    def reply_target_for(conversation:, reply_to_message:)
      conversation = conversation.canonical
      return unless conversation.invoice.present?
      return unless reply_to_message.account_id == conversation.account_id
      return unless reply_to_message.conversation_id.in?(conversation.conversation_group_ids)
      return unless safe_anchor?(reply_to_message)

      recipient = verified_recipient(
        customer: conversation.customer,
        message: reply_to_message
      )
      ReplyTarget.new(message: reply_to_message, recipient:) if recipient
    end

    def recipient_for(conversation:, reply_to_message:)
      reply_target_for(
        conversation:,
        reply_to_message:
      )&.recipient || raise(UnsafeAnchor, "The customer email address could not be verified.")
    end

    def composer_token_for(conversation:, target:)
      conversation = conversation.canonical
      raise UnsafeAnchor, "A safe reply target is required." unless target

      composer_verifier.generate(
        {
          "account_id" => conversation.account_id,
          "conversation_id" => conversation.id,
          "invoice_id" => conversation.invoice_id,
          "customer_id" => conversation.customer_id,
          "anchor_message_id" => target.message.id,
          "recipient" => target.recipient,
          "provider_account_id" => target.message.provider_account_id,
          "provider_thread_id" => target.message.provider_thread_id
        },
        expires_in: 30.minutes,
        purpose: "conversation-manual-reply"
      )
    end

    private
      def composer_verifier
        Rails.application.message_verifier("conversation-manual-reply")
      end

      def safe_anchor?(message)
        message.direction_inbound? &&
          message.kind_customer_email? &&
          message.status_received? &&
          !message.awaiting_review? &&
          !message.review_outcome_no_match_needed? &&
          !message.automatic? &&
          !malformed_or_spam?(message) &&
          message.provider_account_id.present? &&
          message.provider_thread_id.present? &&
          message.internet_message_id.present?
      end

      def verified_recipient(customer:, message:)
        return unless customer

        known_addresses = customer.reminder_email_addresses
        reply_to = normalized_addresses(message.reply_to_addresses)
        from = message.from_address.to_s.strip.downcase.presence

        return reply_to.first if reply_to.one? && known_addresses.include?(reply_to.first)
        from if from && known_addresses.include?(from)
      end

      def malformed_or_spam?(message)
        message.review_reasons.include?("spam") ||
          Array(message.provider_metadata["parse_warnings"]).any?
      end

      def normalized_addresses(addresses)
        Array(addresses).filter_map { |address| address.to_s.strip.downcase.presence }.uniq
      end
  end

  def self.enqueue!(
    conversation:,
    reply_to_message:,
    actor_user:,
    body:,
    idempotency_key:,
    composer_token:,
    at: Time.current
  )
    new(
      conversation:,
      reply_to_message:,
      actor_user:,
      body:,
      idempotency_key:,
      composer_token:,
      at:
    ).enqueue!
  end

  def initialize(
    conversation:,
    reply_to_message:,
    actor_user:,
    body:,
    idempotency_key:,
    composer_token:,
    at:
  )
    @conversation = conversation.canonical
    @reply_to_message = reply_to_message
    @actor_user = actor_user
    @body = body.to_s.strip
    @idempotency_key = idempotency_key.to_s.strip
    @composer_token = composer_token.to_s
    @at = at
    @account = @conversation.account
  end

  def enqueue!
    validate_request!
    existing = find_existing
    return validate_existing!(existing) if existing

    message = nil
    job = nil
    created = false

    conversation.with_lock do
      if existing = find_existing
        message = validate_existing!(existing)
        next
      end

      recipient = validate_composer!
      validate_anchor!
      validate_composer_freshness!
      connection = delivery_connection!
      job = ConversationMessages::ManualReplyJob.new(
        account.id,
        nil,
        reply_to_message.provider_thread_id
      )
      message = conversation.conversation_messages.create!(
        account:,
        invoice: conversation.invoice,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        requested_provider_account_id: reply_to_message.provider_account_id,
        requested_provider_thread_id: reply_to_message.provider_thread_id,
        reply_to_message:,
        actor_user:,
        direction: :outbound,
        kind: :manual_reply,
        status: :pending,
        delivery_job_id: job.job_id,
        from_address: connection.connected_email,
        to_addresses: [ recipient ],
        cc_addresses: [],
        bcc_addresses: [],
        reply_to_addresses: [],
        subject: reply_subject,
        body:,
        in_reply_to_message_ids: [ reply_to_message.internet_message_id ],
        reference_message_ids: reply_references,
        matching_status: :matched,
        matching_method: :gmail_thread,
        idempotency_key:
      )
      ConversationEvent.create!(
        account:,
        conversation:,
        conversation_message: message,
        kind: :conversation_manual_reply_queued,
        actor_kind: :user,
        actor_user:,
        metadata: {
          "reply_to_message_id" => reply_to_message.id
        },
        created_at: at
      )
      created = true
    end

    enqueue_job!(job, message) if created
    message
  rescue ActiveRecord::RecordNotUnique
    validate_existing!(find_existing!)
  end

  private
    attr_reader :account,
      :conversation,
      :reply_to_message,
      :actor_user,
      :body,
      :idempotency_key,
      :composer_token,
      :at

    def validate_request!
      unless actor_user.account_id == account.id &&
          reply_to_message.account_id == account.id &&
          reply_to_message.conversation_id.in?(conversation.conversation_group_ids)
        raise ActiveRecord::RecordNotFound
      end
      raise UnsafeAnchor, "Replies require an invoice-backed conversation." if conversation.invoice.blank?
      raise ArgumentError, "Reply body is required." if body.blank?
      if body.length > MAXIMUM_BODY_LENGTH
        raise ArgumentError, "Reply body is too long."
      end
      raise ArgumentError, "Idempotency token is required." if idempotency_key.blank?
      raise StaleComposer, "This reply form is stale. Refresh and try again." if composer_token.blank?
    end

    def validate_anchor!
      return if self.class.reply_target_for(
        conversation:,
        reply_to_message:
      )

      raise UnsafeAnchor, "This email cannot be replied to safely."
    end

    def validate_composer_freshness!
      ConversationMessages::ThreadedReply.ensure_fresh!(
        conversation:,
        reply_to_message:
      )
    end

    def delivery_connection!
      connection = account.email_connection
      ready = connection&.gmail_ready? &&
        connection.sender_matches?(account.invoice_reminder_from_email) &&
        connection.provider_account_id == reply_to_message.provider_account_id
      raise DeliveryUnavailable, "Gmail is not ready for replies." unless ready

      connection
    end

    def safe_recipient!
      self.class.recipient_for(
        conversation:,
        reply_to_message:
      )
    end

    def validate_composer!
      payload = self.class.send(:composer_verifier).verify(
        composer_token,
        purpose: "conversation-manual-reply"
      )
      target = self.class.reply_target_for(
        conversation:,
        reply_to_message:
      )
      expected = {
        "account_id" => account.id,
        "conversation_id" => conversation.id,
        "invoice_id" => conversation.invoice_id,
        "customer_id" => conversation.customer_id,
        "anchor_message_id" => reply_to_message.id,
        "recipient" => target&.recipient,
        "provider_account_id" => reply_to_message.provider_account_id,
        "provider_thread_id" => reply_to_message.provider_thread_id
      }
      unless target && payload == expected
        raise StaleComposer, "This reply form is stale. Refresh and try again."
      end

      target.recipient
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise StaleComposer, "This reply form is stale. Refresh and try again."
    end

    def reply_subject
      original = reply_to_message.subject.to_s.strip.presence || "Customer email"
      original.match?(/\Are:/i) ? original : "Re: #{original}"
    end

    def reply_references
      [
        *reply_to_message.reference_message_ids,
        *reply_to_message.in_reply_to_message_ids,
        reply_to_message.internet_message_id
      ].compact.uniq
    end

    def find_existing
      account.conversation_messages.find_by(idempotency_key:)
    end

    def find_existing!
      account.conversation_messages.find_by!(idempotency_key:)
    end

    def validate_existing!(existing)
      expected = {
        conversation_id: conversation.id,
        reply_to_message_id: reply_to_message.id,
        actor_user_id: actor_user.id,
        body:
      }
      exact_request = existing.kind_manual_reply? && existing.valid? && expected.all? do |attribute, value|
        existing.public_send(attribute) == value
      end
      unless exact_request
        raise IdempotencyConflict, "That reply token was already used."
      end

      existing
    end

    def enqueue_job!(job, message)
      job.arguments[1] = message.id
      enqueued = job.enqueue
      unless enqueued
        raise(job.enqueue_error || ActiveJob::EnqueueError.new("Could not enqueue manual reply"))
      end
    rescue StandardError
      message.mark_delivery_failed!(
        job_id: message.delivery_job_id,
        failure_reason: "Reply could not be queued."
      )
      ConversationMessages::ManualReplyOutcome.finalize!(message)
      false
    end
end

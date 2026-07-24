class ConversationAi::Eligibility
  Decision = Data.define(:eligible, :local_decision, :reason, :owner) do
    alias_method :eligible?, :eligible
  end
  EXCLUDED_LABELS = %w[DRAFT TRASH SPAM SENT].freeze

  class << self
    def decision(message, explicit: false)
      new(message, explicit:).decision
    end

    def analysis_key(message:, configuration:, guidance_revision:, generation: 1)
      parts = [
        message.id,
        message.provider_account_id,
        message.provider_message_id,
        configuration.provider,
        configuration.model,
        ConversationAi::Prompts::ClassifierV1::PROMPT_VERSION,
        ConversationAi::ProviderRegistry.fetch(configuration.provider)::ADAPTER_VERSION,
        ConversationAi::OutputSchema::VERSION,
        ConversationAi::Planner::VERSION,
        ConversationActions::Catalog::TEMPLATE_VERSION,
        guidance_revision&.id,
        generation
      ]
      Digest::SHA256.hexdigest(parts.join(":"))
    end
  end

  def initialize(message, explicit: false)
    @message = message
    @explicit = explicit
  end

  def decision
    return rejected("mode_off") unless account.conversation_ai_mode_shadow?
    return rejected("not_inbound") unless message.direction_inbound?
    return rejected("not_received") unless message.status_received?
    return rejected("before_shadow_enabled") if
      !explicit &&
        (
          account.conversation_ai_enabled_at.blank? ||
          message.received_at < account.conversation_ai_enabled_at
        )
    return rejected("not_gmail_import") if message.email_connection_id.blank?
    return rejected("excluded_label") if excluded_label?
    return rejected("mailbox_replaced") unless current_mailbox?
    return rejected("not_matched") unless confidently_matched?

    owner = Conversations::ReviewWorkUnit.workflow_owner_for(
      conversation: message.conversation
    )
    return rejected("invoice_unmatched") if owner.invoice.blank? || owner.customer.blank?
    return local("automatic_reply", "no_action", owner) if message.automatic?

    authored = ConversationMessages::AuthoredContent.extract(message)
    return local(
      authored.warnings.include?("no_authored_content") ?
        "no_authored_content" :
        "unreliable_authored_content",
      "human_review",
      owner
    ) unless authored.reliable?

    Decision.new(
      eligible: true,
      local_decision: nil,
      reason: nil,
      owner:
    )
  rescue Conversations::ReviewWorkUnit::SplitInvoiceWorkUnit
    rejected("split_invoice_work_unit")
  end

  private
    attr_reader :message, :explicit

    def account
      @account ||= Account.find(message.account_id)
    end

    def rejected(reason)
      Decision.new(eligible: false, local_decision: nil, reason:, owner: nil)
    end

    def local(reason, local_decision, owner)
      Decision.new(eligible: true, local_decision:, reason:, owner:)
    end

    def excluded_label?
      labels = Array(message.provider_metadata["label_ids"]).map(&:to_s)
      labels.intersect?(EXCLUDED_LABELS)
    end

    def current_mailbox?
      connection = message.email_connection
      connection.present? &&
        connection.provider_account_id == message.provider_account_id &&
        connection.credential_generation == message.email_connection_generation
    end

    def confidently_matched?
      message.matching_status_matched? ||
        (
          message.matching_status_ambiguous? &&
          message.review_outcome_manual_match? &&
          message.reviewed_at.present?
        )
    end
end

class ConversationActions::Commands::Base
  def self.call(**attributes)
    new(**attributes).call
  end

  def initialize(execution:, action:, revision:, definition:, conversation:, invoice:, source_message:, at:)
    @execution = execution
    @action = action
    @revision = revision
    @definition = definition
    @conversation = conversation
    @invoice = invoice
    @source_message = source_message
    @at = at
  end

  private
    attr_reader :execution,
      :action,
      :revision,
      :definition,
      :conversation,
      :invoice,
      :source_message,
      :at

    def result(
      result_code:,
      result_metadata: {},
      payment_promise: nil,
      customer_email_address: nil,
      collection_hold: nil,
      effect_escalation: nil,
      effect_mutated: false,
      rendered_reply: nil,
      cc_addresses: [],
      attention_required: false
    )
      ConversationActions::CommandResult.new(
        result_code:,
        result_metadata:,
        payment_promise:,
        customer_email_address:,
        collection_hold:,
        effect_escalation:,
        effect_mutated:,
        rendered_reply:,
        cc_addresses:,
        attention_required:
      )
    end

    def render_reply(outcome: {})
      ConversationActions::ReplyRenderer.render!(
        definition:,
        invoice:,
        account: execution.account,
        at:,
        outcome:
      )
    end

    def open_escalation!(
      category: :other,
      priority: :high,
      summary:,
      details: nil,
      collection_hold: nil,
      suffix:
    )
      ConversationEscalations::Opening.call(
        conversation:,
        category:,
        priority:,
        summary:,
        details:,
        source_message:,
        conversation_action: action,
        collection_hold:,
        opened_by_kind: :system,
        idempotency_key: "action-execution:#{execution.id}:#{suffix}",
        at:
      )
    end
end

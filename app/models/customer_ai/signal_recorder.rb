class CustomerAi::SignalRecorder
  BLOCKED_GUIDANCE = /
    mark\s+(?:the\s+)?invoice\s+paid|
    skip\s+reminder|delay\s+reminder|add\s+recipient|ignore\s+(?:policy|cooldown)|
    send\s+automatically|release\s+hold|accept\s+dispute
  /ix

  class << self
    def record!(interpretation)
      new(interpretation).record!
    end
  end

  def initialize(interpretation)
    @interpretation = interpretation
  end

  def record!
    target = anchored_target
    return [] unless target

    Array(interpretation.structured_result["feedback_signals"])
      .first(ConversationAi::OutputSchema::MAXIMUM_SIGNALS)
      .filter_map.with_index do |attributes, index|
        next if generic_thanks?(attributes)
        guidance = compact_guidance(attributes.fetch("proposed_guidance"))
        next if unsafe_guidance?(guidance)

        interpretation.customer_ai_signals.create_or_find_by!(
          idempotency_key: "signal:#{index}:#{Digest::SHA256.hexdigest(JSON.generate(attributes))}"
        ) do |signal|
          signal.account = interpretation.account
          signal.customer = interpretation.customer
          signal.source_message = interpretation.source_message
          signal.target_outbound_message = target
          signal.signal_type = attributes.fetch("type")
          signal.confidence_bps = attributes.fetch("confidence_bps")
          signal.evidence = attributes.fetch("evidence")
          signal.proposed_guidance = guidance
          signal.status = :proposed
          signal.decider_snapshot = {}
        end
      end
  end

  private
    attr_reader :interpretation

    def anchored_target
      source = interpretation.source_message
      ids = [
        *Array(source.in_reply_to_message_ids),
        *Array(source.reference_message_ids).reverse
      ].uniq
      ids.each do |internet_message_id|
        digest = Digest::SHA256.hexdigest(internet_message_id)
        candidate = source.account.conversation_messages
          .direction_outbound
          .where(internet_message_id_digest: digest)
          .find_by(internet_message_id:)
        next unless candidate
        next unless candidate.occurred_at < source.occurred_at
        next unless Conversations::ReviewWorkUnit.includes_message?(
          conversation: interpretation.conversation,
          message: candidate
        )

        return candidate
      end
      nil
    end

    def generic_thanks?(attributes)
      return false unless attributes["type"] == "positive_response"

      quote = attributes.dig("evidence", "quote").to_s
      quote.match?(/\A\s*(?:thanks|thank you)[.!]?\s*\z/i)
    end

    def compact_guidance(guidance)
      guidance.to_h.select { |_key, value| value.present? }
    end

    def unsafe_guidance?(guidance)
      guidance.empty? || JSON.generate(guidance).match?(BLOCKED_GUIDANCE)
    end
end

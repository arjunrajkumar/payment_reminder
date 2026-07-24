class CustomerAi::GuidanceAttributes
  class << self
    def normalize(attributes)
      values = attributes.to_h.deep_stringify_keys
        .slice(*CustomerAiGuidanceRevision::ALLOWED_GUIDANCE_KEYS)
      phrases = values["phrases_to_avoid"]
      values["phrases_to_avoid"] = normalize_phrases(phrases) if phrases.present?
      values.select { |_key, value| value.present? }
    end

    private
      def normalize_phrases(value)
        Array(value).flat_map { |item| item.to_s.split(/[\r\n,]+/) }
          .map(&:strip)
          .reject(&:blank?)
          .uniq
          .first(10)
      end
  end
end

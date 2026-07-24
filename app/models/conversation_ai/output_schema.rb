class ConversationAi::OutputSchema
  VERSION = "conversation_interpretation_v1"
  MAXIMUM_INTENTS = 3
  MAXIMUM_SIGNALS = 3
  MESSAGE_KINDS = %w[
    customer_request customer_feedback unrelated automatic_reply ambiguous
  ].freeze
  INTENT_TYPES = %w[
    payment_promise question_due_date question_payment_status
    question_outstanding_amount resend_invoice add_recipient dispute
    other_requires_person
  ].freeze
  EVIDENCE_FIELDS = %w[subject authored_body trusted_header].freeze
  RECIPIENT_MODES = %w[permanent cc_current_reply].freeze
  SIGNAL_TYPES = CustomerAiSignal::SIGNAL_TYPES.keys.freeze

  class InvalidResult < StandardError; end

  class << self
    def schema
      {
        "type" => "object",
        "additionalProperties" => false,
        "required" => %w[
          schema_version message_kind language overall_confidence_bps
          requires_human summary concise_rationale reason_codes intents
          proposed_reply feedback_signals
        ],
        "properties" => {
          "schema_version" => string_enum([ VERSION ]),
          "message_kind" => string_enum(MESSAGE_KINDS),
          "language" => bounded_string(32),
          "overall_confidence_bps" => integer_bps,
          "requires_human" => { "type" => "boolean" },
          "summary" => bounded_string(1_000),
          "concise_rationale" => bounded_string(2_000),
          "reason_codes" => bounded_string_array(10, 100),
          "intents" => {
            "type" => "array",
            "maxItems" => MAXIMUM_INTENTS,
            "items" => intent_schema
          },
          "proposed_reply" => proposed_reply_schema,
          "feedback_signals" => {
            "type" => "array",
            "maxItems" => MAXIMUM_SIGNALS,
            "items" => feedback_signal_schema
          }
        }
      }
    end

    def validate_provider_result!(result, context:)
      exact_object!(
        result,
        %w[
          schema_version message_kind language overall_confidence_bps
          requires_human summary concise_rationale reason_codes intents
          proposed_reply feedback_signals
        ],
        "result"
      )
      invalid!("Wrong result schema version.") unless
        result["schema_version"] == VERSION
      enum!(result["message_kind"], MESSAGE_KINDS, "message_kind")
      bounded_string!(result["language"], "language", 32)
      bps!(result["overall_confidence_bps"], "overall_confidence_bps")
      invalid!("requires_human must be boolean.") unless
        [ true, false ].include?(result["requires_human"])
      bounded_string!(result["summary"], "summary", 1_000)
      bounded_string!(result["concise_rationale"], "concise_rationale", 2_000)
      string_array!(result["reason_codes"], "reason_codes", 10, 100)
      array!(result["intents"], "intents", MAXIMUM_INTENTS)
      result["intents"].each_with_index do |intent, index|
        validate_intent!(intent, context:, index:)
      end
      validate_proposed_reply!(result["proposed_reply"])
      array!(result["feedback_signals"], "feedback_signals", MAXIMUM_SIGNALS)
      result["feedback_signals"].each_with_index do |signal, index|
        validate_feedback_signal!(signal, context:, index:)
      end
      result.deep_dup
    end

    private
      def intent_schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => %w[type confidence_bps evidence values],
          "properties" => {
            "type" => string_enum(INTENT_TYPES),
            "confidence_bps" => integer_bps,
            "evidence" => {
              "type" => "array",
              "maxItems" => 5,
              "items" => evidence_schema
            },
            "values" => {
              "type" => "object",
              "additionalProperties" => false,
              "required" => %w[
                promised_on original_date_text email mode dispute_summary
              ],
              "properties" => {
                "promised_on" => nullable_string(10),
                "original_date_text" => nullable_string(100),
                "email" => nullable_string(254),
                "mode" => {
                  "type" => [ "string", "null" ],
                  "enum" => [ *RECIPIENT_MODES, nil ]
                },
                "dispute_summary" => nullable_string(500)
              }
            }
          }
        }
      end

      def evidence_schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => %w[source_key field quote purpose],
          "properties" => {
            "source_key" => bounded_string(100),
            "field" => string_enum(EVIDENCE_FIELDS),
            "quote" => bounded_string(500),
            "purpose" => bounded_string(200)
          }
        }
      end

      def proposed_reply_schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => %w[greeting acknowledgement closing tone_hints outline],
          "properties" => {
            "greeting" => nullable_string(500),
            "acknowledgement" => nullable_string(500),
            "closing" => nullable_string(500),
            "tone_hints" => bounded_string_array(5, 100),
            "outline" => bounded_string_array(8, 300)
          }
        }
      end

      def feedback_signal_schema
        {
          "type" => "object",
          "additionalProperties" => false,
          "required" => %w[type confidence_bps evidence proposed_guidance],
          "properties" => {
            "type" => string_enum(SIGNAL_TYPES),
            "confidence_bps" => integer_bps,
            "evidence" => evidence_schema,
            "proposed_guidance" => {
              "type" => "object",
              "additionalProperties" => false,
              "required" => CustomerAiGuidanceRevision::ALLOWED_GUIDANCE_KEYS,
              "properties" => {
                "preferred_tone" => nullable_string(100),
                "preferred_language" => nullable_string(32),
                "preferred_salutation" => nullable_string(100),
                "preferred_concision" => nullable_string(100),
                "communication_notes" => nullable_string(500),
                "phrases_to_avoid" => {
                  "type" => "array",
                  "maxItems" => 10,
                  "items" => bounded_string(100)
                }
              }
            }
          }
        }
      end

      def validate_intent!(intent, context:, index:)
        name = "intents[#{index}]"
        exact_object!(intent, %w[type confidence_bps evidence values], name)
        enum!(intent["type"], INTENT_TYPES, "#{name}.type")
        bps!(intent["confidence_bps"], "#{name}.confidence_bps")
        array!(intent["evidence"], "#{name}.evidence", 5)
        invalid!("#{name}.evidence is required.") if intent["evidence"].empty?
        intent["evidence"].each_with_index do |evidence, evidence_index|
          validate_evidence!(
            evidence,
            context:,
            name: "#{name}.evidence[#{evidence_index}]"
          )
        end
        exact_object!(
          intent["values"],
          %w[promised_on original_date_text email mode dispute_summary],
          "#{name}.values"
        )
        intent["values"].each do |key, value|
          next if value.nil?

          maximum = {
            "promised_on" => 10,
            "original_date_text" => 100,
            "email" => 254,
            "mode" => 20,
            "dispute_summary" => 500
          }.fetch(key)
          bounded_string!(value, "#{name}.values.#{key}", maximum)
        end
        enum!(intent.dig("values", "mode"), [ *RECIPIENT_MODES, nil ], "#{name}.values.mode")
      end

      def validate_proposed_reply!(reply)
        exact_object!(
          reply,
          %w[greeting acknowledgement closing tone_hints outline],
          "proposed_reply"
        )
        %w[greeting acknowledgement closing].each do |key|
          bounded_string!(reply[key], "proposed_reply.#{key}", 500) if reply[key]
        end
        string_array!(reply["tone_hints"], "proposed_reply.tone_hints", 5, 100)
        string_array!(reply["outline"], "proposed_reply.outline", 8, 300)
      end

      def validate_feedback_signal!(signal, context:, index:)
        name = "feedback_signals[#{index}]"
        exact_object!(signal, %w[type confidence_bps evidence proposed_guidance], name)
        enum!(signal["type"], SIGNAL_TYPES, "#{name}.type")
        bps!(signal["confidence_bps"], "#{name}.confidence_bps")
        validate_evidence!(signal["evidence"], context:, name: "#{name}.evidence")
        exact_object!(
          signal["proposed_guidance"],
          CustomerAiGuidanceRevision::ALLOWED_GUIDANCE_KEYS,
          "#{name}.proposed_guidance"
        )
        signal["proposed_guidance"].each do |key, value|
          next if value.nil?

          if key == "phrases_to_avoid"
            string_array!(
              value,
              "#{name}.proposed_guidance.#{key}",
              10,
              100
            )
          else
            maximum = key == "communication_notes" ? 500 : 100
            bounded_string!(
              value,
              "#{name}.proposed_guidance.#{key}",
              maximum
            )
          end
        end
      end

      def validate_evidence!(evidence, context:, name:)
        exact_object!(evidence, %w[source_key field quote purpose], name)
        enum!(evidence["field"], EVIDENCE_FIELDS, "#{name}.field")
        bounded_string!(evidence["source_key"], "#{name}.source_key", 100)
        bounded_string!(evidence["quote"], "#{name}.quote", 500)
        bounded_string!(evidence["purpose"], "#{name}.purpose", 200)
        source = context.fetch("evidence_sources", {})
          .dig(evidence["source_key"], evidence["field"])
          .to_s
        invalid!("#{name}.quote is not present in its allowed context source.") unless
          source.include?(evidence["quote"])
      end

      def exact_object!(value, keys, name)
        invalid!("#{name} must be an object.") unless
          value.is_a?(Hash) && value.keys.all?(String)
        missing = keys - value.keys
        unknown = value.keys - keys
        invalid!("#{name} is missing required keys.") if missing.any?
        invalid!("#{name} contains unknown keys.") if unknown.any?
      end

      def bounded_string!(value, name, maximum)
        invalid!("#{name} must be bounded text.") unless
          value.is_a?(String) && value.length <= maximum
      end

      def bps!(value, name)
        invalid!("#{name} must be integer basis points.") unless
          value.is_a?(Integer) && value.between?(0, 10_000)
      end

      def enum!(value, allowed, name)
        invalid!("#{name} is unsupported.") unless allowed.include?(value)
      end

      def array!(value, name, maximum)
        invalid!("#{name} must be a bounded array.") unless
          value.is_a?(Array) && value.length <= maximum
      end

      def string_array!(value, name, maximum_items, maximum_length)
        array!(value, name, maximum_items)
        value.each { |item| bounded_string!(item, name, maximum_length) }
      end

      def invalid!(message)
        raise InvalidResult, message
      end

      def string_enum(values)
        { "type" => "string", "enum" => values }
      end

      def bounded_string(maximum)
        { "type" => "string", "maxLength" => maximum }
      end

      def nullable_string(maximum)
        { "type" => [ "string", "null" ], "maxLength" => maximum }
      end

      def integer_bps
        { "type" => "integer", "minimum" => 0, "maximum" => 10_000 }
      end

      def bounded_string_array(maximum_items, maximum_length)
        {
          "type" => "array",
          "maxItems" => maximum_items,
          "items" => bounded_string(maximum_length)
        }
      end
  end
end

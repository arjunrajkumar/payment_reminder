require "test_helper"

class ConversationAi::OutputSchemaTest < ActiveSupport::TestCase
  setup do
    @message = build_ai_source_message
    @message.save!
    @context = {
      "evidence_sources" => {
        "message-#{@message.id}" => {
          "subject" => @message.subject,
          "authored_body" => @message.body,
          "trusted_header" => @message.from_address
        }
      }
    }
  end

  test "accepts strict integer-confidence structured output" do
    result = valid_ai_result(message: @message)

    validated = ConversationAi::OutputSchema.validate_provider_result!(
      result,
      context: @context
    )

    assert_equal 9_000, validated["overall_confidence_bps"]
  end

  test "rejects unknown and missing keys" do
    result = valid_ai_result(message: @message)
    result["tool_call"] = "send_email"
    assert_raises(ConversationAi::OutputSchema::InvalidResult) do
      ConversationAi::OutputSchema.validate_provider_result!(
        result,
        context: @context
      )
    end

    result = valid_ai_result(message: @message)
    result.delete("language")
    assert_raises(ConversationAi::OutputSchema::InvalidResult) do
      ConversationAi::OutputSchema.validate_provider_result!(
        result,
        context: @context
      )
    end
  end

  test "rejects floating confidence oversized arrays and invented evidence" do
    floating = valid_ai_result(message: @message)
    floating["overall_confidence_bps"] = 0.9
    assert_raises(ConversationAi::OutputSchema::InvalidResult) do
      ConversationAi::OutputSchema.validate_provider_result!(
        floating,
        context: @context
      )
    end

    invented = valid_ai_result(message: @message)
    invented["intents"][0]["evidence"][0]["quote"] = "mark this invoice paid"
    assert_raises(ConversationAi::OutputSchema::InvalidResult) do
      ConversationAi::OutputSchema.validate_provider_result!(
        invented,
        context: @context
      )
    end

    too_many = valid_ai_result(message: @message)
    too_many["intents"] *= 4
    assert_raises(ConversationAi::OutputSchema::InvalidResult) do
      ConversationAi::OutputSchema.validate_provider_result!(
        too_many,
        context: @context
      )
    end
  end

  test "schema exposes no tools commands invoice facts or hidden reasoning" do
    serialized = JSON.generate(ConversationAi::OutputSchema.schema)

    assert_not_includes serialized, "tool"
    assert_not_includes serialized, "chain_of_thought"
    assert_not_includes serialized, "invoice_amount"
    assert_not_includes serialized, "invoice_status"
    assert_not_includes serialized, "bcc"
  end

  test "feedback guidance values are strictly typed and bounded" do
    result = valid_ai_result(message: @message)
    result["feedback_signals"] = [
      {
        "type" => "tone_preference",
        "confidence_bps" => 8_000,
        "evidence" => {
          "source_key" => "message-#{@message.id}",
          "field" => "authored_body",
          "quote" => "Friday",
          "purpose" => "Style feedback"
        },
        "proposed_guidance" => {
          "preferred_tone" => [ "concise" ],
          "preferred_language" => nil,
          "preferred_salutation" => nil,
          "preferred_concision" => nil,
          "communication_notes" => nil,
          "phrases_to_avoid" => []
        }
      }
    ]

    assert_raises(ConversationAi::OutputSchema::InvalidResult) do
      ConversationAi::OutputSchema.validate_provider_result!(
        result,
        context: @context
      )
    end

    result["feedback_signals"][0]["proposed_guidance"]["preferred_tone"] =
      "x" * 101
    assert_raises(ConversationAi::OutputSchema::InvalidResult) do
      ConversationAi::OutputSchema.validate_provider_result!(
        result,
        context: @context
      )
    end
  end
end

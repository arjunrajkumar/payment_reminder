require "test_helper"

class ConversationAi::PlannerTest < ActiveSupport::TestCase
  MAPPINGS = {
    "payment_promise" => "record_payment_promise",
    "question_due_date" => "answer_due_date",
    "question_payment_status" => "answer_payment_status",
    "question_outstanding_amount" => "answer_outstanding_amount",
    "resend_invoice" => "resend_invoice",
    "dispute" => "open_dispute",
    "other_requires_person" => "other"
  }.freeze

  test "maps every supported single intent through the existing catalog" do
    MAPPINGS.each do |intent_type, action_type|
      message = build_ai_source_message(
        body: intent_type == "dispute" ?
          "I dispute this charge." :
          "I will pay Friday."
      )
      message.save!
      values = base_values
      values["promised_on"] = 2.days.from_now.to_date.iso8601 if
        intent_type == "payment_promise"
      values["original_date_text"] = "Friday" if intent_type == "payment_promise"
      values["dispute_summary"] = "dispute this charge" if intent_type == "dispute"
      interpretation = build_interpretation(
        message:,
        result: result_for(message:, intent_type:, values:)
      )

      assert_no_difference -> { ConversationAction.count } do
        plan = ConversationAi::Planner.plan(interpretation)
        assert_equal "propose_action", plan.decision
        assert_equal action_type, plan.proposed_action_type
        ConversationActions::Catalog.validate!(
          action_type: plan.proposed_action_type,
          arguments: plan.arguments,
          proposed_reply: plan.proposed_reply
        )
      end
    end
  end

  test "maps permanent and one-time recipients without BCC" do
    [
      [ "permanent", "future_reminders" ],
      [ "cc_current_reply", "cc_current_reply" ]
    ].each do |provider_mode, catalog_mode|
      message = build_ai_source_message(
        body: "Please copy new@example.com."
      )
      message.save!
      values = base_values.merge(
        "email" => "new@example.com",
        "mode" => provider_mode
      )
      interpretation = build_interpretation(
        message:,
        result: result_for(
          message:,
          intent_type: "add_recipient",
          values:,
          evidence_quote: "new@example.com"
        )
      )

      plan = ConversationAi::Planner.plan(interpretation)

      assert_equal "propose_action", plan.decision
      assert_equal "add_recipient", plan.proposed_action_type
      assert_equal catalog_mode, plan.arguments["mode"]
      assert_not_includes plan.arguments.keys, "bcc"
    end
  end

  test "confidence boundary is explicit immediately below at and above threshold" do
    [ 8_499, 8_500, 8_501 ].each do |confidence|
      message = build_ai_source_message
      message.save!
      interpretation = build_interpretation(
        message:,
        result: result_for(
          message:,
          intent_type: "payment_promise",
          values: base_values.merge(
            "promised_on" => 2.days.from_now.to_date.iso8601,
            "original_date_text" => "Friday"
          ),
          confidence:
        )
      )

      expected = confidence < ConversationAi::Planner::CONFIDENCE_THRESHOLD_BPS ?
        "human_review" :
        "propose_action"
      assert_equal expected, ConversationAi::Planner.plan(interpretation).decision
    end
  end

  test "multi-intent ambiguous unsupported language and unreliable extraction require review" do
    message = build_ai_source_message
    message.save!
    base = result_for(
      message:,
      intent_type: "payment_promise",
      values: base_values.merge(
        "promised_on" => 2.days.from_now.to_date.iso8601,
        "original_date_text" => "Friday"
      )
    )
    variants = [
      base.merge("intents" => base["intents"] * 2),
      base.merge("message_kind" => "ambiguous", "requires_human" => true),
      base.merge("language" => "fr"),
      base
    ]
    warnings = [ [], [], [], [ "attachment_only" ] ]

    variants.each_with_index do |result, index|
      interpretation = build_interpretation(
        message:,
        result:,
        warnings: warnings[index]
      )
      assert_equal "human_review",
        ConversationAi::Planner.plan(interpretation).decision
    end
  end

  test "automatic and unrelated mail produce no action" do
    %w[automatic_reply unrelated].each do |kind|
      message = build_ai_source_message
      message.save!
      result = result_for(
        message:,
        intent_type: "question_due_date",
        values: base_values
      ).merge(
        "message_kind" => kind,
        "intents" => []
      )
      interpretation = build_interpretation(message:, result:)

      assert_equal "no_action",
        ConversationAi::Planner.plan(interpretation).decision
    end
  end

  test "past impossible extreme and missing promise dates require review" do
    [
      1.day.ago.to_date.iso8601,
      "2026-02-30",
      "9999-12-31",
      nil
    ].each do |date|
      message = build_ai_source_message
      message.save!
      values = base_values.merge(
        "promised_on" => date,
        "original_date_text" => "Friday"
      )
      interpretation = build_interpretation(
        message:,
        result: result_for(
          message:,
          intent_type: "payment_promise",
          values:
        )
      )

      assert_equal "human_review",
        ConversationAi::Planner.plan(interpretation).decision
    end
  end

  private
    def build_interpretation(message:, result:, warnings: [])
      message.account.conversation_interpretations.create!(
        conversation: message.conversation.canonical,
        source_message: message,
        invoice: message.invoice,
        customer: message.invoice.customer,
        requested_mode: :shadow,
        status: :succeeded,
        analysis_key: SecureRandom.hex(32),
        input_digest: SecureRandom.hex(32),
        context_snapshot: {},
        authored_content_snapshot: message.body,
        authored_content_warnings: warnings,
        source_identity_snapshot: { "message_id" => message.id },
        semantic_prompt_version: "classifier_v1",
        provider_adapter_version: "test_adapter_v1",
        result_schema_version: ConversationAi::OutputSchema::VERSION,
        planner_version: ConversationAi::Planner::VERSION,
        catalog_version: ConversationActions::Catalog::TEMPLATE_VERSION.to_s,
        provider: "openai",
        requested_model: "model-x",
        accepted_model: "model-x",
        scheduling_status: :consumed,
        message_kind: result["message_kind"],
        language: result["language"],
        overall_confidence_bps: result["overall_confidence_bps"],
        requires_human: result["requires_human"],
        summary: result["summary"],
        concise_rationale: result["concise_rationale"],
        reason_codes: result["reason_codes"],
        structured_result: result,
        completed_at: Time.current
      )
    end

    def result_for(
      message:,
      intent_type:,
      values:,
      confidence: 9_000,
      evidence_quote: nil
    )
      evidence_quote ||= case intent_type
      when "payment_promise" then "Friday"
      when "dispute" then "dispute this charge"
      else message.body.first(30)
      end
      valid_ai_result(
        message:,
        intent_type:,
        overall_confidence_bps: confidence,
        intent_confidence_bps: confidence,
        values:
      ).tap do |result|
        result["intents"][0]["evidence"][0]["quote"] = evidence_quote
      end
    end

    def base_values
      {
        "promised_on" => nil,
        "original_date_text" => nil,
        "email" => nil,
        "mode" => nil,
        "dispute_summary" => nil
      }
    end
end

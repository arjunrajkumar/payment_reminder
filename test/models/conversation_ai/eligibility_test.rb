require "test_helper"

class ConversationAi::EligibilityTest < ActiveSupport::TestCase
  setup do
    @account = enable_ai_shadow!
  end

  test "accepts one matched inbound message and deduplicates repeated requests" do
    message = build_ai_source_message
    message.save!
    configuration = stub(
      available?: true,
      provider: "openai",
      model: "configured-model"
    )
    ConversationAi::Configuration.stubs(:for).returns(configuration)

    assert_difference -> { ConversationInterpretation.count }, 1 do
      3.times { ConversationAi::AnalysisRequest.enqueue_for(message) }
    end
    assert_equal 1,
      ConversationInterpretation.where(source_message: message).count
    identity = message.conversation_interpretations.sole
      .source_identity_snapshot
    assert_equal message.invoice.number, identity["invoice_number"]
    assert_equal message.invoice.customer.name, identity["customer_name"]
    assert_equal message.subject, identity["source_subject"]
  end

  test "off mode and pre-enable history do not schedule implicitly" do
    historical = build_ai_source_message(received_at: 2.days.ago)
    historical.save!

    assert_equal "before_shadow_enabled",
      ConversationAi::Eligibility.decision(historical).reason

    @account.update_columns(conversation_ai_mode: "off")
    current = build_ai_source_message
    current.save!

    assert_equal "mode_off", ConversationAi::Eligibility.decision(current).reason
    assert_nil ConversationAi::AnalysisRequest.enqueue_for(current)
  end

  test "explicit reanalysis may select a historical eligible message" do
    historical = build_ai_source_message(received_at: 2.days.ago)
    historical.save!

    assert_predicate ConversationAi::Eligibility.decision(
      historical,
      explicit: true
    ), :eligible?
  end

  test "automatic reply is a deterministic local no-action result" do
    message = build_ai_source_message(automatic: true)
    message.save!

    decision = ConversationAi::Eligibility.decision(message)

    assert_predicate decision, :eligible?
    assert_equal "no_action", decision.local_decision
    assert_equal "automatic_reply", decision.reason
  end

  test "empty attachment and parse-failed messages stay with a human" do
    %w[attachment_only body_parse_failed].each do |warning|
      message = build_ai_source_message(
        body: "",
        provider_metadata: {
          "label_ids" => [ "INBOX" ],
          "parse_warnings" => [ warning ]
        }
      )
      message.save!

      decision = ConversationAi::Eligibility.decision(message)

      assert_predicate decision, :eligible?
      assert_equal "human_review", decision.local_decision
    end
  end

  test "draft trash spam sent and unmatched messages never call AI" do
    %w[DRAFT TRASH SPAM SENT].each do |label|
      message = build_ai_source_message(
        provider_metadata: {
          "label_ids" => [ label ],
          "parse_warnings" => []
        }
      )
      message.save!
      assert_equal "excluded_label",
        ConversationAi::Eligibility.decision(message).reason
    end

    unmatched = build_ai_source_message(
      matching_status: :unmatched,
      matching_method: :customer_only
    )
    unmatched.save!
    assert_equal "not_matched",
      ConversationAi::Eligibility.decision(unmatched).reason
  end

  test "known manual and app-created outbound messages are rejected" do
    message = build_ai_source_message(
      direction: :outbound,
      kind: :manual_email,
      status: :sent,
      received_at: nil,
      sent_at: Time.current,
      from_address: "billing@paymentreminder.example",
      to_addresses: [ "customer@example.com" ]
    )
    message.save!

    assert_equal "not_inbound", ConversationAi::Eligibility.decision(message).reason
  end

  test "replaced Gmail identity cannot reuse mailbox context" do
    message = build_ai_source_message
    message.save!
    message.update_columns(provider_account_id: "replaced-mailbox")

    assert_equal "mailbox_replaced",
      ConversationAi::Eligibility.decision(message.reload).reason
  end

  test "manual matching makes an ambiguous message eligible once" do
    message = build_ai_source_message(
      matching_status: :ambiguous,
      matching_method: :none,
      review_required: true,
      review_outcome: :manual_match,
      reviewed_at: Time.current,
      reviewed_by_user: users(:arjun)
    )
    message.save!

    assert_predicate ConversationAi::Eligibility.decision(message), :eligible?
  end
end

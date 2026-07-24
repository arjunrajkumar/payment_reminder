require "test_helper"

class ConversationAi::EvaluationCorpusTest < ActiveSupport::TestCase
  CORPUS_PATH = Rails.root.join(
    "test/fixtures/files/conversation_ai_evaluation_corpus.json"
  )
  REQUIRED_TAGS = %w[
    payment_promise promised_on question_due_date question_payment_status
    question_outstanding_amount resend_invoice add_recipient email permanent
    cc_current_reply dispute dispute_summary other_requires_person unrelated
    automatic_reply multi_intent low_confidence ambiguous quoted_history
    contradiction prompt_injection fake_json recipient_injection bcc
    positive_response negative_response anchored_feedback untrusted_feedback
    unsupported_language mixed_language truncation attachment_only
  ].freeze

  test "checked-in corpus is synthetic bounded and covers the adversarial matrix" do
    cases = JSON.parse(File.read(CORPUS_PATH))
    tags = cases.flat_map { |entry| entry.fetch("tags") }.uniq

    assert_equal cases.size, cases.map { |entry| entry.fetch("id") }.uniq.size
    assert_empty REQUIRED_TAGS - tags
    assert cases.all? { |entry| entry.fetch("body").length <= 1_000 }
    assert cases.all? do |entry|
      entry.fetch("expected_decision").in?(
        ConversationAiPlan::DECISIONS.keys
      )
    end
    assert_not_includes JSON.generate(cases), "@gmail.com"
    assert_not_includes JSON.generate(cases), "@example.com"
  end
end

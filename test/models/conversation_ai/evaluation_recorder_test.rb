require "test_helper"

class ConversationAi::EvaluationRecorderTest < ActiveSupport::TestCase
  setup do
    @message = build_ai_source_message
    @message.save!
    @interpretation = create_interpretation_with_plan(@message)
    @user = users(:arjun)
  end

  test "feedback is append-only idempotent and corrections supersede without deletion" do
    first_key = SecureRandom.uuid
    first = record(verdict: "correct", key: first_key)

    assert_equal first, record(verdict: "correct", key: first_key)
    assert_equal 1, @interpretation.conversation_ai_evaluations.count

    second = record(
      verdict: "incorrect",
      key: SecureRandom.uuid,
      corrected_message_kind: "customer_request",
      corrected_action_type: "answer_due_date",
      note: "This was a due-date question."
    )

    assert_equal first, second.supersedes_evaluation
    assert_equal 2, @interpretation.conversation_ai_evaluations.count
    assert_equal [ second ], @interpretation.conversation_ai_evaluations.latest
  end

  test "conflicting idempotent replay and stale signed control are rejected" do
    key = SecureRandom.uuid
    record(verdict: "correct", key:)
    assert_raises(ConversationAi::EvaluationRecorder::Conflict) do
      record(verdict: "incorrect", key:)
    end

    stale_key = SecureRandom.uuid
    token = ConversationAi::EvaluationSnapshot.token_for(
      interpretation: @interpretation,
      idempotency_key: stale_key
    )
    ConversationAiPlan.where(
      id: @interpretation.conversation_ai_plan.id
    ).update_all(
      status: "superseded",
      superseded_at: Time.current
    )
    assert_raises(ConversationAi::EvaluationSnapshot::Stale) do
      ConversationAi::EvaluationRecorder.record!(
        interpretation: @interpretation.reload,
        actor_user: @user,
        token:,
        idempotency_key: stale_key,
        verdict: "unsure"
      )
    end
  end

  test "actor snapshot survives deletion and cross-account feedback is rejected" do
    actor = @message.account.users.create!(name: "Temporary reviewer", role: :member)
    key = SecureRandom.uuid
    evaluation = ConversationAi::EvaluationRecorder.record!(
      interpretation: @interpretation,
      actor_user: actor,
      token: ConversationAi::EvaluationSnapshot.token_for(
        interpretation: @interpretation,
        idempotency_key: key
      ),
      idempotency_key: key,
      verdict: "unsure"
    )
    actor.destroy!

    assert_nil evaluation.reload.actor_user
    assert_equal "Temporary reviewer", evaluation.actor_snapshot["name"]

    other_account = Account.create!(name: "Other AI account")
    other_user = other_account.users.create!(name: "Outsider", role: :member)
    assert_raises(ActiveRecord::RecordNotFound) do
      ConversationAi::EvaluationRecorder.record!(
        interpretation: @interpretation,
        actor_user: other_user,
        token: "invalid",
        idempotency_key: SecureRandom.uuid,
        verdict: "correct"
      )
    end
  ensure
    other_account&.destroy!
  end

  test "report separates correct incorrect unsure and unreviewed denominator" do
    record(verdict: "correct", key: SecureRandom.uuid)
    report = ConversationAi::Report.new(account: @message.account)

    assert_equal 100.0, report.accuracy
    assert_equal 1, report.evaluation_distribution["correct"]
    assert_equal 0, report.evaluation_distribution.fetch("unreviewed", 0)
  end

  private
    def record(
      verdict:,
      key:,
      corrected_message_kind: nil,
      corrected_action_type: nil,
      note: nil
    )
      ConversationAi::EvaluationRecorder.record!(
        interpretation: @interpretation,
        actor_user: @user,
        token: ConversationAi::EvaluationSnapshot.token_for(
          interpretation: @interpretation,
          idempotency_key: key
        ),
        idempotency_key: key,
        verdict:,
        corrected_message_kind:,
        corrected_action_type:,
        corrected_arguments: {},
        note:
      )
    end

    def create_interpretation_with_plan(message)
      interpretation = message.account.conversation_interpretations.create!(
        conversation: message.conversation,
        source_message: message,
        invoice: message.invoice,
        customer: message.invoice.customer,
        requested_mode: :shadow,
        status: :succeeded,
        analysis_key: SecureRandom.hex(32),
        input_digest: SecureRandom.hex(32),
        context_snapshot: {},
        authored_content_snapshot: message.body,
        authored_content_warnings: [],
        source_identity_snapshot: { "message_id" => message.id },
        semantic_prompt_version: "classifier_v1",
        provider_adapter_version: "test_v1",
        result_schema_version: ConversationAi::OutputSchema::VERSION,
        planner_version: ConversationAi::Planner::VERSION,
        catalog_version: "1",
        provider: "openai",
        requested_model: "model-x",
        accepted_model: "model-x",
        scheduling_status: :consumed,
        message_kind: "ambiguous",
        language: "en",
        overall_confidence_bps: 5_000,
        requires_human: true,
        summary: "Needs review",
        concise_rationale: "Ambiguous",
        reason_codes: [ "ambiguous" ],
        structured_result: {
          "intents" => [],
          "feedback_signals" => []
        },
        completed_at: Time.current,
        finalized_at: Time.current
      )
      interpretation.create_conversation_ai_plan!(
        account: message.account,
        decision: :human_review,
        proposed_action_type: nil,
        arguments: {},
        proposed_reply: {},
        user_facing_summary: "Needs review",
        planner_reason_codes: [ "ambiguous" ],
        confidence_bps: 5_000,
        planner_version: ConversationAi::Planner::VERSION,
        catalog_version: "1",
        status: :current
      )
      interpretation
    end
end

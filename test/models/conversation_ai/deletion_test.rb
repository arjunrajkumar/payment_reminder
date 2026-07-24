require "test_helper"

class ConversationAi::DeletionTest < ActiveSupport::TestCase
  test "AI evidence rejects independent deletion and account deletion removes it safely" do
    account = accounts(:paid_jar)
    message = build_ai_source_message
    message.save!
    interpretation = create_interpretation(message)
    invocation = interpretation.conversation_ai_invocations.create!(
      account:,
      attempt_number: 1,
      claim_generation: 1,
      attempt_token: SecureRandom.hex(16),
      provider: "openai",
      endpoint: "https://api.openai.com/v1/responses",
      api_version: "responses_v1",
      provider_adapter_version: "openai_v1",
      requested_model: "model-x",
      application_request_id: SecureRandom.uuid,
      status: :failed,
      sanitized_request: {},
      sanitized_response: {},
      failure_category: "authentication",
      provider_metadata: {},
      started_at: 1.minute.ago,
      finished_at: Time.current
    )
    plan = interpretation.create_conversation_ai_plan!(
      account:,
      decision: :human_review,
      arguments: {},
      proposed_reply: {},
      user_facing_summary: "Review",
      planner_reason_codes: [],
      planner_version: "planner-v1",
      catalog_version: "1",
      status: :current
    )

    assert_raises(ActiveRecord::ReadOnlyRecord) { interpretation.delete }
    assert_raises(ActiveRecord::ReadOnlyRecord) { invocation.delete }
    assert_raises(ActiveRecord::ReadOnlyRecord) { plan.delete }

    ids = [ interpretation.id, invocation.id, plan.id ]
    account.destroy!

    assert_not ConversationInterpretation.exists?(ids[0])
    assert_not ConversationAiInvocation.exists?(ids[1])
    assert_not ConversationAiPlan.exists?(ids[2])
  end

  test "customer deletion clears profiles and related AI evidence safely" do
    customer = customers(:xero_customer)
    message = build_ai_source_message
    message.save!
    interpretation = create_interpretation(message)
    profile = CustomerAiProfile.create!(account: customer.account, customer:)
    revision = profile.guidance_revisions.create!(
      account: customer.account,
      revision_number: 1,
      status: :active,
      author_kind: :user,
      author_snapshot: { "name" => "Reviewer" },
      summary: "Concise",
      structured_guidance: { "preferred_concision" => "concise" },
      evidence_snapshot: {},
      idempotency_key: SecureRandom.uuid,
      activated_at: Time.current
    )
    profile.update!(active_guidance_revision: revision)

    customer.destroy!

    assert_not CustomerAiProfile.exists?(profile.id)
    assert_not CustomerAiGuidanceRevision.exists?(revision.id)
    assert_not ConversationInterpretation.exists?(interpretation.id)
  end

  private
    def create_interpretation(message)
      message.account.conversation_interpretations.create!(
        conversation: message.conversation,
        source_message: message,
        invoice: message.invoice,
        customer: message.invoice.customer,
        requested_mode: :shadow,
        status: :failed,
        analysis_key: SecureRandom.hex(32),
        context_snapshot: {},
        authored_content_warnings: [],
        source_identity_snapshot: {
          "message_id" => message.id,
          "customer_name" => message.invoice.customer.name
        },
        semantic_prompt_version: "classifier_v1",
        provider_adapter_version: "openai_v1",
        result_schema_version: ConversationAi::OutputSchema::VERSION,
        planner_version: "planner-v1",
        catalog_version: "1",
        provider: "openai",
        requested_model: "model-x",
        scheduling_status: :exhausted,
        reason_codes: [],
        structured_result: {},
        failure_category: "authentication",
        failure_reason: "bad key",
        completed_at: Time.current
      )
    end
end

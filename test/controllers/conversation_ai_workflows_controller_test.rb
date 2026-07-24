require "test_helper"

class ConversationAiWorkflowsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = sign_up_and_complete
    @actor = @account.users.active.where.not(role: :system).sole
    @invoice = create_invoice(@account)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @message = create_message(@conversation)
    @interpretation = create_interpretation(@message)
    @plan = create_plan(@interpretation)
  end

  test "detail presents escaped shadow evidence without approval or execution controls" do
    get conversation_url(@conversation)

    assert_response :success
    assert_select "*", text: /Shadow only — nothing was sent or changed/
    assert_select "[data-testid='ai-interpretation-#{@interpretation.id}']" do
      assert_select "script", count: 0
      assert_select "*", text: /Human review/
      assert_select "form[action=?]",
        conversation_ai_evaluations_path(@conversation)
      assert_select "button", { text: /Approve|Execute/, count: 0 }
    end
    assert_select "body", text: /<script>alert\('ai'\)<\/script>/
  end

  test "signed evaluation is account scoped and append only" do
    key = SecureRandom.uuid
    token = ConversationAi::EvaluationSnapshot.token_for(
      interpretation: @interpretation,
      idempotency_key: key
    )

    assert_difference -> { @interpretation.conversation_ai_evaluations.count }, 1 do
      post conversation_ai_evaluations_url(@conversation), params: {
        conversation_interpretation_id: @interpretation.id,
        ai_evaluation: {
          token:,
          idempotency_key: key,
          verdict: "incorrect",
          corrected_message_kind: "customer_request",
          corrected_action_type: "other",
          corrected_arguments: "{}",
          note: "Needs a person."
        }
      }
    end

    assert_redirected_to conversation_path(@conversation)
    assert_equal "Needs a person.",
      @interpretation.conversation_ai_evaluations.sole.note

    other_interpretation = create_other_account_interpretation
    assert_no_difference -> { ConversationAiEvaluation.count } do
      post conversation_ai_evaluations_url(@conversation), params: {
        conversation_interpretation_id: other_interpretation.id,
        ai_evaluation: {
          token: "forged",
          idempotency_key: SecureRandom.uuid,
          verdict: "correct"
        }
      }
    end
    assert_response :not_found
  end

  test "signal approval accepts bounded edits and manual revision stays human governed" do
    outbound = create_message(
      @conversation,
      direction: :outbound,
      kind: :manual_email,
      status: :sent,
      received_at: nil,
      sent_at: 2.hours.ago,
      internet_message_id: "<ai-controller-outbound@example.com>"
    )
    signal = @interpretation.customer_ai_signals.create!(
      account: @account,
      customer: @invoice.customer,
      source_message: @message,
      target_outbound_message: outbound,
      signal_type: :tone_preference,
      confidence_bps: 8_000,
      evidence: { "quote" => "Please be concise." },
      proposed_guidance: { "preferred_tone" => "formal" },
      status: :proposed,
      decider_snapshot: {},
      idempotency_key: SecureRandom.uuid
    )
    key = SecureRandom.uuid

    post conversation_customer_ai_signal_approval_url(
      @conversation,
      signal
    ), params: {
      customer_ai_signal_approval: {
        token: CustomerAi::GuidanceSnapshot.token_for(
          signal:,
          idempotency_key: key
        ),
        idempotency_key: key,
        summary: "Use a concise, warm tone",
        structured_guidance: {
          preferred_tone: "warm",
          preferred_concision: "concise",
          phrases_to_avoid: "urgent, final warning"
        },
        note: "Edited and approved by a user."
      }
    }

    assert_redirected_to conversation_path(@conversation)
    revision = signal.reload.guidance_revisions.sole
    assert_equal "warm", revision.structured_guidance["preferred_tone"]
    assert_equal [ "urgent", "final warning" ],
      revision.structured_guidance["phrases_to_avoid"]

    profile = @invoice.customer.reload.customer_ai_profile
    assert_difference -> {
      profile.guidance_revisions.count
    }, 1 do
      post customer_ai_guidance_revisions_url(@invoice.customer), params: {
        ai_guidance_revision: {
          idempotency_key: SecureRandom.uuid,
          summary: "Prefer the first name",
          structured_guidance: {
            preferred_salutation: "Use the customer's first name"
          }
        }
      }, headers: {
        "HTTP_REFERER" => conversation_url(@conversation)
      }
    end
    assert_redirected_to conversation_path(@conversation)
  end

  test "member sees interpretation versions but not provider diagnostics" do
    @interpretation.conversation_ai_invocations.create!(
      account: @account,
      attempt_number: 1,
      claim_generation: 1,
      attempt_token: SecureRandom.hex(16),
      provider: "openai",
      endpoint: ConversationAi::Providers::OpenAi::ENDPOINT,
      api_version: ConversationAi::Providers::OpenAi::API_VERSION,
      provider_adapter_version: "openai_v1",
      requested_model: "model-x",
      returned_model: "model-x",
      application_request_id: SecureRandom.uuid,
      provider_request_id: "private-request-id",
      status: :failed,
      sanitized_request: { "prompt" => "private bounded prompt" },
      sanitized_response: { "body" => "<script>private response</script>" },
      failure_category: "rate_limited",
      failure_message: "rate limited",
      provider_metadata: {},
      started_at: 1.minute.ago,
      finished_at: Time.current
    )
    @actor.update!(role: :member)

    get conversation_url(@conversation)

    assert_response :success
    assert_select "body", text: /classifier_v1/
    assert_select "[data-testid='ai-provider-audit']", count: 0
    assert_select "body", { text: /private bounded prompt/, count: 0 }
    assert_select "body", { text: /private response/, count: 0 }
    assert_select "body", { text: /private-request-id/, count: 0 }
  end

  private
    def sign_up_and_complete(email_address: "ai-workflows@example.com")
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url,
        params: { signup: { full_name: "AI Workflow Reviewer" } }

      Identity.find_by!(email_address:).accounts.first
    end

    def create_invoice(account)
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "ai-workflows-source"
      )
      customer = source.customers.create!(
        account:,
        external_id: "ai-workflows-customer",
        name: "AI Customer",
        email: "ai-customer@example.com"
      )
      source.invoices.create!(
        account:,
        customer:,
        external_id: "ai-workflows-invoice",
        number: "INV-AI-WORKFLOW",
        status: :open
      )
    end

    def create_message(conversation, attributes = {})
      conversation.conversation_messages.create!({
        account: conversation.account,
        invoice: conversation.invoice,
        internet_message_id: "<ai-controller-#{SecureRandom.hex(8)}@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: 1.hour.ago,
        from_address: conversation.customer.email,
        subject: "AI shadow review",
        body: "Please be concise.",
        matching_status: :matched,
        matching_method: :invoice_reference
      }.merge(attributes))
    end

    def create_interpretation(message)
      message.account.conversation_interpretations.create!(
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
        source_identity_snapshot: {},
        semantic_prompt_version: "classifier_v1",
        provider_adapter_version: "openai_v1",
        result_schema_version: ConversationAi::OutputSchema::VERSION,
        planner_version: ConversationAi::Planner::VERSION,
        catalog_version: "1",
        provider: "openai",
        requested_model: "model-x",
        accepted_model: "model-x",
        scheduling_status: :consumed,
        message_kind: "customer_request",
        language: "en",
        overall_confidence_bps: 7_000,
        requires_human: true,
        summary: "<script>alert('ai')</script>",
        concise_rationale: "A person should review this.",
        reason_codes: [ "low_confidence" ],
        structured_result: valid_ai_result(message:).merge(
          "overall_confidence_bps" => 7_000,
          "requires_human" => true
        ),
        completed_at: Time.current,
        finalized_at: Time.current
      )
    end

    def create_plan(interpretation)
      interpretation.create_conversation_ai_plan!(
        account: interpretation.account,
        decision: :human_review,
        arguments: {},
        proposed_reply: {},
        user_facing_summary: "Human review required.",
        planner_reason_codes: [ "low_confidence" ],
        confidence_bps: 7_000,
        planner_version: ConversationAi::Planner::VERSION,
        catalog_version: "1",
        status: :current
      )
    end

    def create_other_account_interpretation
      message = build_ai_source_message
      message.save!
      interpretation = create_interpretation(message)
      create_plan(interpretation)
      interpretation
    end
end

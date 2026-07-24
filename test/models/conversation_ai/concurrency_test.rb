require "test_helper"
require "timeout"

class ConversationAi::ConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    identifiers = Thread.new { create_records }.value
    @account_id,
      @first_user_id,
      @second_user_id,
      @interpretation_id,
      @first_signal_id,
      @second_signal_id = identifiers
  end

  teardown do
    account_id = @account_id
    Thread.new { Account.find_by(id: account_id)&.destroy! }.value if account_id
  end

  test "two reviewers append feedback concurrently without losing either record" do
    interpretation = ConversationInterpretation.find(@interpretation_id)
    attempts = [
      [ @first_user_id, "correct", "concurrent-evaluation-one" ],
      [ @second_user_id, "incorrect", "concurrent-evaluation-two" ]
    ]
    tokens = attempts.to_h do |_user_id, _verdict, key|
      [
        key,
        ConversationAi::EvaluationSnapshot.token_for(
          interpretation:,
          idempotency_key: key
        )
      ]
    end

    results = run_concurrently(attempts) do |user_id, verdict, key|
      ConversationAi::EvaluationRecorder.record!(
        interpretation: ConversationInterpretation.find(@interpretation_id),
        actor_user: User.find(user_id),
        token: tokens.fetch(key),
        idempotency_key: key,
        verdict:
      )
    end

    assert results.all? { |result| result.is_a?(ConversationAiEvaluation) },
      results.map { |result| [ result.class.name, result.to_s ] }.inspect
    evaluations = ConversationAiEvaluation
      .where(conversation_interpretation_id: @interpretation_id)
      .order(:id)
    assert_equal 2, evaluations.count
    assert_equal 1, evaluations.latest.count
    assert_equal 2,
      ConversationEvent.where(
        kind: :conversation_ai_evaluation_recorded,
        conversation_id: interpretation.conversation_id
      ).count
  end

  test "concurrent guidance approvals serialize to exactly one active revision" do
    attempts = [
      [ @first_signal_id, @first_user_id, "warm" ],
      [ @second_signal_id, @second_user_id, "formal" ]
    ]
    tokens = attempts.to_h do |signal_id, _user_id, tone|
      signal = CustomerAiSignal.find(signal_id)
      key = "concurrent-guidance-#{tone}"
      [
        signal_id,
        [
          key,
          CustomerAi::GuidanceSnapshot.token_for(
            signal:,
            idempotency_key: key
          )
        ]
      ]
    end

    results = run_concurrently(attempts) do |signal_id, user_id, tone|
      key, token = tokens.fetch(signal_id)
      CustomerAi::GuidanceDecision.approve!(
        signal: CustomerAiSignal.find(signal_id),
        actor_user: User.find(user_id),
        token:,
        idempotency_key: key,
        summary: "Use a #{tone} tone",
        structured_guidance: { "preferred_tone" => tone }
      )
    end

    assert results.all? { |result| result.is_a?(CustomerAiGuidanceRevision) },
      results.map { |result| [ result.class.name, result.to_s ] }.inspect
    profile = CustomerAiProfile.find_by!(account_id: @account_id)
    revisions = profile.guidance_revisions.order(:revision_number)
    assert_equal [ 1, 2 ], revisions.pluck(:revision_number)
    assert_equal 1, revisions.status_active.count
    assert_equal 1, revisions.status_superseded.count
    assert_equal revisions.status_active.sole,
      profile.reload.active_guidance_revision
  end

  private
    def create_records
      account = Account.create!(
        name: "AI concurrency #{SecureRandom.uuid}"
      )
      first_user = account.users.create!(
        name: "First AI reviewer",
        role: :owner
      )
      second_user = account.users.create!(
        name: "Second AI reviewer",
        role: :member
      )
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: SecureRandom.uuid
      )
      customer = source.customers.create!(
        account:,
        external_id: SecureRandom.uuid,
        name: "AI concurrency customer",
        email: "ai-concurrency@example.test"
      )
      invoice = source.invoices.create!(
        account:,
        customer:,
        external_id: SecureRandom.uuid,
        number: "INV-AI-CONCURRENCY",
        status: :open
      )
      conversation = Conversation.for_invoice!(invoice:)
      outbound = conversation.conversation_messages.create!(
        account:,
        invoice:,
        direction: :outbound,
        kind: :manual_email,
        status: :sent,
        sent_at: 2.hours.ago,
        internet_message_id: "<ai-concurrency-outbound@example.test>",
        from_address: "billing@example.test",
        to_addresses: [ customer.email ],
        body: "Please review your invoice."
      )
      inbound = conversation.conversation_messages.create!(
        account:,
        invoice:,
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: 1.hour.ago,
        internet_message_id: "<ai-concurrency-inbound@example.test>",
        from_address: customer.email,
        body: "Please use a different tone.",
        matching_status: :matched,
        matching_method: :invoice_reference
      )
      interpretation = account.conversation_interpretations.create!(
        conversation:,
        source_message: inbound,
        invoice:,
        customer:,
        requested_mode: :shadow,
        status: :succeeded,
        analysis_key: SecureRandom.hex(32),
        input_digest: SecureRandom.hex(32),
        context_snapshot: {},
        authored_content_snapshot: inbound.body,
        authored_content_warnings: [],
        source_identity_snapshot: {},
        semantic_prompt_version: "classifier_v1",
        provider_adapter_version: "openai_v1",
        result_schema_version: ConversationAi::OutputSchema::VERSION,
        planner_version: ConversationAi::Planner::VERSION,
        catalog_version: ConversationActions::Catalog::TEMPLATE_VERSION.to_s,
        provider: "openai",
        requested_model: "model-x",
        accepted_model: "model-x",
        scheduling_status: :consumed,
        message_kind: "customer_feedback",
        language: "en",
        overall_confidence_bps: 9_000,
        requires_human: true,
        summary: "Customer style feedback.",
        concise_rationale: "A person should review the style preference.",
        reason_codes: [ "requires_human" ],
        structured_result: {
          "feedback_signals" => []
        },
        completed_at: Time.current,
        finalized_at: Time.current
      )
      interpretation.create_conversation_ai_plan!(
        account:,
        decision: :human_review,
        arguments: {},
        proposed_reply: {},
        user_facing_summary: interpretation.summary,
        planner_reason_codes: [ "requires_human" ],
        confidence_bps: 9_000,
        planner_version: ConversationAi::Planner::VERSION,
        catalog_version: ConversationActions::Catalog::TEMPLATE_VERSION.to_s,
        status: :current
      )
      signals = %i[tone_preference concision_preference].map do |type|
        interpretation.customer_ai_signals.create!(
          account:,
          customer:,
          source_message: inbound,
          target_outbound_message: outbound,
          signal_type: type,
          confidence_bps: 9_000,
          evidence: { "quote" => inbound.body },
          proposed_guidance: {},
          status: :proposed,
          decider_snapshot: {},
          idempotency_key: SecureRandom.uuid
        )
      end
      [
        account.id,
        first_user.id,
        second_user.id,
        interpretation.id,
        signals.first.id,
        signals.second.id
      ]
    end

    def run_concurrently(values)
      ready = Queue.new
      start = Queue.new
      threads = values.map do |value|
        Thread.new do
          ready << true
          start.pop
          yield(*value)
        rescue StandardError => error
          error
        end
      end
      values.size.times { Timeout.timeout(2) { ready.pop } }
      values.size.times { start << true }
      threads.map { |thread| Timeout.timeout(10) { thread.value } }
    end
end

require "test_helper"

class ConversationAi::AnalyzerTest < ActiveSupport::TestCase
  setup do
    @account = enable_ai_shadow!
    @message = build_ai_source_message
    @message.save!
    @configuration = stub(
      available?: true,
      validate!: true,
      provider: "openai",
      model: "model-x",
      api_key: "secret"
    )
    ConversationAi::Configuration.stubs(:for).returns(@configuration)
    ConversationAi::Configuration.stubs(:for_provider).returns(@configuration)
    @interpretation = ConversationAi::AnalysisRequest.enqueue_for(@message)
  end

  test "successful analysis persists one invocation and plan with no business effect" do
    client = stub(analyze: provider_result)

    assert_no_difference [
      -> { ConversationAction.count },
      -> { PaymentPromise.count },
      -> { CollectionHold.count },
      -> { ConversationEscalation.count },
      -> { ConversationMessage.direction_outbound.count }
    ] do
      ConversationAi::Analyzer.call(
        interpretation_id: @interpretation.id,
        scheduling_generation: @interpretation.scheduling_generation,
        client:
      )
    end

    interpretation = @interpretation.reload
    assert_predicate interpretation, :status_succeeded?
    assert_predicate interpretation, :finalized_at?
    assert_equal "propose_action", interpretation.conversation_ai_plan.decision
    assert_equal "record_payment_promise",
      interpretation.conversation_ai_plan.proposed_action_type
    assert_equal 1, interpretation.conversation_ai_invocations.count
    assert_predicate interpretation.conversation_ai_invocations.first,
      :status_succeeded?
  end

  test "retryable failure records one invocation and durable bounded retry" do
    error = ConversationAi::ProviderError.new(
      category: "rate_limited",
      message: "slow down",
      response_status: 429,
      retry_after_seconds: 30,
      sanitized_request: { "model" => "model-x" }
    )
    client = mock
    client.expects(:analyze).once.raises(error)

    ConversationAi::Analyzer.call(
      interpretation_id: @interpretation.id,
      scheduling_generation: @interpretation.scheduling_generation,
      client:
    )

    interpretation = @interpretation.reload
    assert_predicate interpretation, :status_pending?
    assert_predicate interpretation, :scheduling_reserved?
    assert_operator interpretation.next_retry_at, :>, Time.current
    invocation = interpretation.conversation_ai_invocations.first
    assert_predicate invocation, :status_failed?
    assert_equal "rate_limited", invocation.failure_category
    assert_equal 1, interpretation.provider_attempts
  end

  test "authentication refusal malformed and unexpected model failures are terminal" do
    failures = [
      ConversationAi::ProviderError.new(
        category: "authentication",
        message: "bad key"
      ),
      ConversationAi::ProviderError.new(
        category: "refusal",
        message: "refused"
      ),
      ConversationAi::ProviderError.new(
        category: "malformed_output",
        message: "wrong schema"
      )
    ]
    failures.each do |error|
      interpretation = fresh_interpretation
      client = stub
      client.stubs(:analyze).raises(error)

      ConversationAi::Analyzer.call(
        interpretation_id: interpretation.id,
        scheduling_generation: interpretation.scheduling_generation,
        client:
      )

      assert_predicate interpretation.reload, :status_failed?
      assert_nil interpretation.conversation_ai_plan
    end

    interpretation = fresh_interpretation
    wrong_model = provider_result(
      message: interpretation.source_message,
      returned_model: "different-model"
    )
    ConversationAi::Analyzer.call(
      interpretation_id: interpretation.id,
      scheduling_generation: interpretation.scheduling_generation,
      client: stub(analyze: wrong_model)
    )
    assert_predicate interpretation.reload, :status_failed?
    assert_equal "unsupported_model", interpretation.failure_category
  end

  test "mode disable while request is in flight retains superseded audit only" do
    client = Object.new
    account = @account
    result = provider_result
    client.define_singleton_method(:analyze) do |request:|
      account.update_columns(conversation_ai_mode: "off")
      result
    end

    ConversationAi::Analyzer.call(
      interpretation_id: @interpretation.id,
      scheduling_generation: @interpretation.scheduling_generation,
      client:
    )

    interpretation = @interpretation.reload
    assert_predicate interpretation, :status_canceled?
    assert_nil interpretation.conversation_ai_plan
    assert_predicate interpretation.conversation_ai_invocations.first,
      :status_superseded?
  end

  test "claim lost before response cannot persist result plan signals or health" do
    client = Object.new
    interpretation_id = @interpretation.id
    result = provider_result
    client.define_singleton_method(:analyze) do |request:|
      ConversationInterpretation.where(id: interpretation_id).update_all(
        status: ConversationInterpretation.statuses.fetch(:pending),
        scheduling_status: ConversationInterpretation
          .scheduling_statuses.fetch(:reserved),
        scheduling_enqueued_at: nil,
        scheduling_consumed_at: nil,
        claim_token: nil,
        claimed_at: nil,
        next_scheduling_at: Time.current,
        next_retry_at: Time.current,
        updated_at: Time.current
      )
      result
    end

    ConversationAi::Analyzer.call(
      interpretation_id: @interpretation.id,
      scheduling_generation: @interpretation.scheduling_generation,
      client:
    )

    interpretation = @interpretation.reload
    assert_predicate interpretation, :status_pending?
    assert_nil interpretation.conversation_ai_plan
    assert_empty interpretation.customer_ai_signals
    assert_predicate interpretation.conversation_ai_invocations.first,
      :status_superseded?
  end

  test "stale claim reconciliation closes the invocation and fences a late response" do
    client = Object.new
    interpretation_id = @interpretation.id
    result = provider_result
    fake_job = stub
    client.define_singleton_method(:analyze) do |request:|
      ConversationInterpretation.where(id: interpretation_id).update_all(
        claimed_at: 1.hour.ago
      )
      ConversationAi::AnalyzeJob.stubs(:perform_later).returns(fake_job)
      ConversationAi::Reconciler.call(at: Time.current)
      result
    end

    ConversationAi::Analyzer.call(
      interpretation_id: @interpretation.id,
      scheduling_generation: @interpretation.scheduling_generation,
      client:
    )

    interpretation = @interpretation.reload
    assert_predicate interpretation, :status_pending?
    assert_nil interpretation.conversation_ai_plan
    invocation = interpretation.conversation_ai_invocations.first
    assert_predicate invocation, :status_superseded?
    assert_equal "stale_claim", invocation.failure_category
    assert_predicate invocation, :finished_at?
  end

  test "later inbound message supersedes stale historical plan" do
    later = build_ai_source_message(
      provider_thread_id: @message.provider_thread_id,
      body: "Correction: I cannot pay Friday.",
      received_at: @message.received_at + 1.minute
    )
    client = Object.new
    result = provider_result
    client.define_singleton_method(:analyze) do |request:|
      later.save!
      result
    end

    ConversationAi::Analyzer.call(
      interpretation_id: @interpretation.id,
      scheduling_generation: @interpretation.scheduling_generation,
      client:
    )

    interpretation = @interpretation.reload
    assert_predicate interpretation, :status_superseded?
    assert_predicate interpretation.conversation_ai_plan, :status_superseded?
  end

  test "a later completed interpretation supersedes an earlier current result" do
    ConversationAi::Analyzer.call(
      interpretation_id: @interpretation.id,
      scheduling_generation: @interpretation.scheduling_generation,
      client: stub(analyze: provider_result)
    )
    earlier = @interpretation.reload
    assert_predicate earlier, :status_succeeded?

    later_message = build_ai_source_message(
      provider_thread_id: @message.provider_thread_id,
      body: "Correction: I will pay Friday.",
      received_at: @message.received_at + 1.minute
    )
    later_message.save!
    later = ConversationAi::AnalysisRequest.enqueue_for(later_message)

    ConversationAi::Analyzer.call(
      interpretation_id: later.id,
      scheduling_generation: later.scheduling_generation,
      client: stub(analyze: provider_result(message: later_message))
    )

    assert_predicate later.reload, :status_succeeded?
    assert_predicate earlier.reload, :status_superseded?
    assert_predicate earlier.conversation_ai_plan.reload, :status_superseded?
    assert_equal later.id,
      ConversationEvent.find_by!(
        ai_event_key: "ai:#{earlier.id}:superseded-by:#{later.id}"
      )
        .metadata["superseded_by_interpretation_id"]
  end

  private
    def fresh_interpretation
      message = build_ai_source_message
      message.save!
      ConversationAi::AnalysisRequest.enqueue_for(message)
    end

    def provider_result(message: @message, returned_model: "model-x")
      ConversationAi::ProviderResult.new(
        structured_output: valid_ai_result(message:),
        provider: "openai",
        provider_request_id: "request-123",
        requested_model: "model-x",
        returned_model:,
        input_tokens: 10,
        cached_input_tokens: 2,
        output_tokens: 5,
        total_tokens: 15,
        latency_ms: 20,
        sanitized_request: { "model" => "model-x" },
        sanitized_response: { "id" => "response-123" },
        provider_metadata: {}
      )
    end
end

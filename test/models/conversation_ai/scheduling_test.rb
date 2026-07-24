require "test_helper"

class ConversationAi::SchedulingTest < ActiveSupport::TestCase
  setup do
    @account = enable_ai_shadow!
    @configuration = stub(
      available?: true,
      provider: "openai",
      model: "model-x"
    )
    ConversationAi::Configuration.stubs(:for).returns(@configuration)
  end

  test "false and raised enqueue release exact reservations" do
    [ false, RuntimeError.new("queue unavailable") ].each do |outcome|
      message = build_ai_source_message
      message.save!
      if outcome == false
        ConversationAi::AnalyzeJob.stubs(:perform_later).returns(false)
      else
        ConversationAi::AnalyzeJob.stubs(:perform_later).raises(outcome)
      end

      interpretation = ConversationAi::AnalysisRequest.enqueue_for(message)

      assert_predicate interpretation.reload, :scheduling_reserved?
      assert_nil interpretation.scheduling_token
      assert_equal 1, interpretation.scheduling_attempts
      assert_predicate interpretation, :last_scheduling_error?
      ConversationAi::AnalyzeJob.unstub(:perform_later)
    end
  end

  test "scheduling failures exhaust visibly without touching collection state" do
    message = build_ai_source_message
    message.save!
    fake_job = stub
    ConversationAi::AnalyzeJob.stubs(:perform_later).returns(fake_job)
    interpretation = ConversationAi::AnalysisRequest.enqueue_for(message)
    ConversationInterpretation.where(id: interpretation.id).update_all(
      status: "pending",
      scheduling_status: "reserved",
      scheduling_attempts: 4,
      scheduling_token: nil,
      scheduling_claimed_at: nil,
      scheduling_enqueued_at: nil,
      scheduling_consumed_at: nil
    )
    interpretation.reload
    assert_equal 4, interpretation.scheduling_attempts
    ConversationAi::AnalyzeJob.unstub(:perform_later)
    ConversationAi::AnalyzeJob.stubs(:perform_later).returns(false)

    assert_no_difference [
      -> { CollectionHold.count },
      -> { ConversationEscalation.count },
      -> { InvoiceReminder.count }
    ] do
      assert_not ConversationAi::AnalysisRequest.schedule(interpretation)
    end

    assert_predicate interpretation.reload, :status_failed?
    assert_predicate interpretation, :scheduling_exhausted?
    assert_equal "scheduling_exhausted", interpretation.failure_category
  end

  test "reconciler releases stale scheduling owner and only current generation claims" do
    message = build_ai_source_message
    message.save!
    ConversationAi::AnalyzeJob.stubs(:perform_later).returns(stub)
    interpretation = ConversationAi::AnalysisRequest.enqueue_for(message)
    ConversationInterpretation.where(id: interpretation.id).update_all(
      status: "pending",
      scheduling_status: "claimed",
      scheduling_token: "stale-token",
      scheduling_claimed_at: 1.hour.ago,
      scheduling_generation: 4,
      scheduling_enqueued_at: nil,
      scheduling_consumed_at: nil
    )
    interpretation.reload
    assert_equal 4, interpretation.scheduling_generation

    ConversationAi::Reconciler.call(at: Time.current)

    interpretation.reload
    assert_operator interpretation.scheduling_generation, :>, 4
    assert_predicate interpretation, :scheduling_enqueued?
    ConversationAi::Analyzer.call(
      interpretation_id: interpretation.id,
      scheduling_generation: 4,
      client: mock
    )
    assert_predicate interpretation.reload, :status_pending?
    assert_empty interpretation.conversation_ai_invocations
  end

  test "two reconciliation passes do not duplicate one due scheduling generation" do
    message = build_ai_source_message
    message.save!
    ConversationAi::AnalyzeJob.stubs(:perform_later).returns(stub)
    interpretation = ConversationAi::AnalysisRequest.enqueue_for(message)
    ConversationInterpretation.where(id: interpretation.id).update_all(
      status: "pending",
      scheduling_status: "reserved",
      scheduling_token: nil,
      scheduling_claimed_at: nil,
      scheduling_enqueued_at: nil,
      scheduling_consumed_at: nil,
      next_scheduling_at: 1.minute.ago
    )
    ConversationAi::AnalyzeJob.unstub(:perform_later)
    calls = 0
    ConversationAi::AnalyzeJob.stubs(:perform_later)
      .with { |_id, _generation| calls += 1; true }
      .returns(stub)

    2.times { ConversationAi::Reconciler.call(at: Time.current) }

    assert_equal 1, calls
    assert_predicate interpretation.reload, :scheduling_enqueued?
  end

  test "missing-analysis sweep repairs a manually matched message once" do
    message = build_ai_source_message(
      matching_status: :ambiguous,
      matching_method: :none,
      review_required: true,
      review_outcome: :manual_match,
      reviewed_at: Time.current,
      reviewed_by_user: users(:arjun)
    )
    message.save!
    ConversationAi::AnalyzeJob.stubs(:perform_later).returns(stub)

    assert_difference -> {
      ConversationInterpretation.where(source_message: message).count
    }, 1 do
      2.times { ConversationAi::Reconciler.call(at: Time.current) }
    end

    assert_predicate message.conversation_interpretations.sole,
      :scheduling_enqueued?
  end

  test "finalization sweep repairs completed evidence without rerunning AI" do
    message = build_ai_source_message(automatic: true)
    message.save!
    interpretation = ConversationAi::AnalysisRequest.enqueue_for(message)
    ConversationInterpretation.where(id: interpretation.id)
      .update_all(finalized_at: nil)
    ConversationEvent.where(
      ai_event_key: [
        "ai:#{interpretation.id}:skipped",
        "ai:#{interpretation.id}:plan"
      ]
    ).delete_all

    ConversationAi::Reconciler.call(at: Time.current)

    assert_predicate interpretation.reload, :finalized_at?
    assert_equal 1,
      ConversationEvent.where(
        ai_event_key: "ai:#{interpretation.id}:skipped"
      ).count
    assert_equal 1,
      ConversationEvent.where(
        ai_event_key: "ai:#{interpretation.id}:plan"
      ).count
    assert_empty interpretation.conversation_ai_invocations
  end
end

require "test_helper"

class ConversationAi::SettingChangeTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @actor = users(:arjun)
    @actor.update!(role: :admin)
    @identity = Identity.create!(email_address: "ai-settings@example.com")
    @actor.update!(identity: @identity)
  end

  test "default mode is off and unavailable provider cannot be enabled" do
    @account.update_columns(
      conversation_ai_mode: "off",
      conversation_ai_provider: nil,
      conversation_ai_enabled_at: nil
    )
    ConversationAi::ProviderRegistry.stubs(:configured).returns([])

    assert_predicate @account.reload, :conversation_ai_mode_off?
    assert_raises(ConversationAi::Configuration::Error) do
      ConversationAi::SettingChange.call(
        account: @account,
        actor_user: @actor,
        actor_identity: @identity,
        mode: "shadow",
        provider: "openai"
      )
    end
  end

  test "administrator selects a configured provider and change is audited" do
    ConversationAi::ProviderRegistry.stubs(:configured)
      .returns(%w[openai anthropic])

    assert_difference -> { PlatformAdminEvent.count }, 1 do
      ConversationAi::SettingChange.call(
        account: @account,
        actor_user: @actor,
        actor_identity: @identity,
        mode: "shadow",
        provider: "anthropic"
      )
    end

    assert_predicate @account.reload, :conversation_ai_mode_shadow?
    assert_equal "anthropic", @account.conversation_ai_provider
    assert_predicate @account, :conversation_ai_enabled_at?
    event = PlatformAdminEvent.order(:id).last
    assert_equal "conversation_ai_mode_changed", event.action
    assert_equal "anthropic", event.metadata.dig("current", "provider")
    assert_not_includes JSON.generate(event.metadata), "API_KEY"
  end

  test "disable cancels queued work and re-enable does not backfill history" do
    ConversationAi::ProviderRegistry.stubs(:configured).returns([ "openai" ])
    ConversationAi::SettingChange.call(
      account: @account,
      actor_user: @actor,
      actor_identity: @identity,
      mode: "shadow",
      provider: "openai"
    )
    enabled_at = @account.reload.conversation_ai_enabled_at
    message = build_ai_source_message(received_at: enabled_at + 1.second)
    message.save!
    interpretation = create_pending_interpretation(message)

    ConversationAi::SettingChange.call(
      account: @account,
      actor_user: @actor,
      actor_identity: @identity,
      mode: "off",
      provider: "openai"
    )

    assert_predicate interpretation.reload, :status_canceled?

    travel 1.minute
    ConversationAi::SettingChange.call(
      account: @account,
      actor_user: @actor,
      actor_identity: @identity,
      mode: "shadow",
      provider: "openai"
    )
    assert_operator @account.reload.conversation_ai_enabled_at, :>, enabled_at
    assert_equal "before_shadow_enabled",
      ConversationAi::Eligibility.decision(message).reason
  end

  test "provider switch cancels queued interpretations but preserves history" do
    ConversationAi::ProviderRegistry.stubs(:configured)
      .returns(%w[openai anthropic])
    @account.update_columns(
      conversation_ai_mode: "shadow",
      conversation_ai_provider: "openai",
      conversation_ai_enabled_at: 1.minute.ago
    )
    message = build_ai_source_message
    message.save!
    interpretation = create_pending_interpretation(message)

    ConversationAi::SettingChange.call(
      account: @account,
      actor_user: @actor,
      actor_identity: @identity,
      mode: "shadow",
      provider: "anthropic"
    )

    assert_predicate interpretation.reload, :status_canceled?
    assert_equal "openai", interpretation.provider
    assert_equal "anthropic", @account.reload.conversation_ai_provider
  end

  private
    def create_pending_interpretation(message)
      message.account.conversation_interpretations.create!(
        conversation: message.conversation,
        source_message: message,
        invoice: message.invoice,
        customer: message.invoice.customer,
        requested_mode: :shadow,
        status: :pending,
        analysis_key: SecureRandom.hex(32),
        context_snapshot: {},
        authored_content_warnings: [],
        source_identity_snapshot: {},
        semantic_prompt_version: "classifier_v1",
        provider_adapter_version: "openai_v1",
        result_schema_version: ConversationAi::OutputSchema::VERSION,
        planner_version: ConversationAi::Planner::VERSION,
        catalog_version: "1",
        provider: "openai",
        requested_model: "model-x",
        scheduling_status: :reserved,
        reason_codes: [],
        structured_result: {}
      )
    end
end

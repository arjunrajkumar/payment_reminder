class ConversationAi::SettingChange
  class << self
    def call(account:, actor_user:, actor_identity:, mode:, provider:)
      new(
        account:,
        actor_user:,
        actor_identity:,
        mode:,
        provider:
      ).call
    end
  end

  def initialize(account:, actor_user:, actor_identity:, mode:, provider:)
    @account = account
    @actor_user = actor_user
    @actor_identity = actor_identity
    @mode = mode.to_s
    @provider = provider.to_s.strip.presence
  end

  def call
    raise ActiveRecord::RecordNotFound unless actor_user.account_id == account.id
    raise ArgumentError, "Choose off or shadow mode." unless mode.in?(%w[off shadow])
    if mode == "shadow"
      raise ConversationAi::Configuration::Error,
        "Choose a configured AI provider." unless
          provider.in?(ConversationAi::ProviderRegistry.configured)
    end

    previous = {
      "mode" => account.conversation_ai_mode,
      "provider" => account.conversation_ai_provider
    }
    account.with_lock do
      account.update!(
        conversation_ai_mode: mode,
        conversation_ai_provider: provider,
        conversation_ai_enabled_at: mode == "shadow" ?
          Time.current :
          account.conversation_ai_enabled_at
      )
    end
    PlatformAdminEvent.record!(
      actor: actor_identity,
      action: "conversation_ai_mode_changed",
      target: account,
      metadata: {
        "actor_user" => ConversationAi::ActorSnapshot.for(actor_user),
        "previous" => previous,
        "current" => {
          "mode" => account.conversation_ai_mode,
          "provider" => account.conversation_ai_provider
        }
      }
    )
    cancel_pending if mode == "off" || previous["provider"] != provider
    account
  end

  private
    attr_reader :account, :actor_user, :actor_identity, :mode, :provider

    def cancel_pending
      account.conversation_interpretations
        .where(status: :pending)
        .find_each do |interpretation|
          interpretation.update!(
            status: :canceled,
            scheduling_status: :canceled,
            scheduling_token: nil,
            scheduling_claimed_at: nil,
            failure_category: "configuration_changed",
            failure_reason: "AI mode or provider selection changed.",
            canceled_at: Time.current
          )
        end
    end
end

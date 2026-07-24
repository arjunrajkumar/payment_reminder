class ConversationAi::Configuration
  class Error < StandardError; end

  PROVIDER_ENV = {
    "openai" => %w[OPENAI_API_KEY OPENAI_MODEL],
    "anthropic" => %w[ANTHROPIC_API_KEY ANTHROPIC_MODEL]
  }.freeze

  attr_reader :provider, :api_key, :model

  class << self
    def for(account:)
      provider = account.conversation_ai_provider.presence ||
        ENV["CONVERSATION_AI_PROVIDER"].to_s.strip.presence
      new(provider:)
    end

    def for_provider(provider)
      new(provider:)
    end
  end

  def initialize(provider:)
    @provider = provider.to_s.strip
    key_name, model_name = PROVIDER_ENV.fetch(@provider, [ nil, nil ])
    @api_key = ENV[key_name].to_s.strip if key_name
    @model = ENV[model_name].to_s.strip if model_name
  end

  def available?
    ConversationAi::ProviderRegistry.names.include?(provider) &&
      api_key.present? &&
      model.present?
  end

  def validate!
    raise Error, "Choose a supported AI provider." unless
      ConversationAi::ProviderRegistry.names.include?(provider)
    raise Error, "#{provider.titleize} API key is not configured." if api_key.blank?
    raise Error, "#{provider.titleize} model is not configured." if model.blank?

    self
  end

  def client
    validate!
    ConversationAi::ProviderRegistry.fetch(provider).new(
      api_key:,
      model:
    )
  end
end

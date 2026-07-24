class ConversationAi::ProviderRegistry
  PROVIDERS = {
    "openai" => "ConversationAi::Providers::OpenAi",
    "anthropic" => "ConversationAi::Providers::Anthropic"
  }.freeze

  class << self
    def names
      PROVIDERS.keys
    end

    def fetch(name)
      class_name = PROVIDERS[name.to_s] ||
        raise(ConversationAi::Configuration::Error, "AI provider is not supported.")
      class_name.safe_constantize ||
        raise(ConversationAi::Configuration::Error, "AI provider adapter is unavailable.")
    end

    def configured
      names.select { |name| ConversationAi::Configuration.for_provider(name).available? }
    end
  end
end

class ConversationAi::Health
  Result = Data.define(
    :mode,
    :provider,
    :model,
    :configured_providers,
    :available,
    :last_success_at,
    :last_failure_at,
    :last_failure_category,
    :pending_count,
    :due_count,
    :stale_count
  )

  class << self
    def call(account:)
      scope = account.conversation_interpretations
      configuration = ConversationAi::Configuration.for(account:)
      last_success = scope.where(status: :succeeded).order(completed_at: :desc).first
      last_failure = scope.where(status: :failed).order(completed_at: :desc).first
      Result.new(
        mode: account.conversation_ai_mode,
        provider: account.conversation_ai_provider,
        model: configuration.model.presence,
        configured_providers: ConversationAi::ProviderRegistry.configured,
        available: configuration.available?,
        last_success_at: last_success&.completed_at,
        last_failure_at: last_failure&.completed_at,
        last_failure_category: last_failure&.failure_category,
        pending_count: scope.where(status: %i[pending running]).count,
        due_count: due_count(scope),
        stale_count: scope.stale_claims.count + scope.stale_scheduling.count
      )
    end

    private
      def due_count(scope)
        scope
          .where(id: scope.due_scheduling.select(:id))
          .or(scope.where(id: scope.due_retry.select(:id)))
          .count
      end
  end
end

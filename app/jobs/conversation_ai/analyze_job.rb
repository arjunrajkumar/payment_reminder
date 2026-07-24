class ConversationAi::AnalyzeJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(interpretation_id, scheduling_generation)
    ConversationAi::Analyzer.call(
      interpretation_id:,
      scheduling_generation:
    )
  end
end

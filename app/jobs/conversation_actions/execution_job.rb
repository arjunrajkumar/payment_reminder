class ConversationActions::ExecutionJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(execution_id, scheduling_generation)
    execution = ConversationActionExecution.find_by(id: execution_id)
    return unless execution
    return unless execution.consume_schedule!(
      generation: scheduling_generation,
      at: Time.current
    )

    ConversationActions::Executor.call(execution:)
  end
end

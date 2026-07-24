class ConversationAi::ReconcileJob < ApplicationJob
  queue_as :default

  def perform
    ConversationAi::Reconciler.call
  end
end

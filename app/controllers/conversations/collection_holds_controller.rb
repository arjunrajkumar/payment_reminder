class Conversations::CollectionHoldsController < ApplicationController
  def create
    conversation = Conversations::ReviewWorkUnit.reconcile_workflow_owner!(
      conversation: Current.account.conversations.find(
        params[:conversation_id]
      )
    )
    attributes = collection_hold_params
    CollectionHolds::Placement.call(
      conversation:,
      reason: attributes.fetch(:reason),
      note: attributes[:note],
      placed_by_kind: :user,
      placed_by_user: Current.user,
      idempotency_key: attributes.fetch(:idempotency_key)
    )

    redirect_to conversation_path(conversation),
      notice: "Automated collection paused for this invoice."
  rescue CollectionHolds::Error,
    ActiveRecord::RecordInvalid,
    ArgumentError => error
    redirect_to conversation_path(conversation), alert: error.message
  end

  private
    def collection_hold_params
      params.require(:collection_hold).permit(
        :reason,
        :note,
        :idempotency_key
      )
    end
end

class Conversations::CollectionHolds::ReleasesController < ApplicationController
  def create
    conversation = Current.account.conversations
      .find(params[:conversation_id])
      .canonical
    hold = Current.account.collection_holds
      .where(conversation:)
      .find(params[:collection_hold_id])
    attributes = release_params
    hold.release!(
      actor_user: Current.user,
      release_note: attributes[:release_note],
      idempotency_key: attributes.fetch(:idempotency_key),
      snapshot_token: attributes.fetch(:hold_snapshot)
    )

    redirect_to conversation_path(conversation),
      notice: "Collection hold released."
  rescue CollectionHolds::Error,
    ActiveRecord::RecordInvalid,
    ArgumentError => error
    redirect_to conversation_path(conversation), alert: error.message
  end

  private
    def release_params
      params.require(:release).permit(
        :release_note,
        :idempotency_key,
        :hold_snapshot
      )
    end
end

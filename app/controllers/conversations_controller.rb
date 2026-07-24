class ConversationsController < ApplicationController
  before_action :set_conversation, only: :show

  def index
    @filter = params[:filter].to_s.presence_in(Conversations::Inbox::FILTERS) || "all"
    @health = EmailConnection::InboxHealth.call(account: Current.account)
    conversations = set_page_and_extract_portion_from(
      Conversations::Inbox.call(account: Current.account, filter: @filter)
    ).load
    @entries = Conversations::Inbox.decorate(
      account: Current.account,
      conversations:
    )
  end

  def show
    owner = Conversations::ReviewWorkUnit.reconcile_workflow_owner!(
      conversation: @conversation
    )
    return redirect_to conversation_path(owner) unless @conversation == owner

    @conversation = owner
    @detail = Conversations::Detail.call(conversation: owner)
    @health = EmailConnection::InboxHealth.call(account: Current.account)
  end

  private
    def set_conversation
      @conversation = Current.account.conversations.find(params[:id])
    end
end

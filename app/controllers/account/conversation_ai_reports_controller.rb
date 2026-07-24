class Account::ConversationAiReportsController < ApplicationController
  def show
    @report = ConversationAi::Report.new(account: Current.account)
  end
end

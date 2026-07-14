class Account::SettingsController < ApplicationController
  before_action :set_account

  def show
    @invoice_sources = InvoiceSource.available_sources_for(@account)
  end

  private
    def set_account
      @account = Current.account
    end
end

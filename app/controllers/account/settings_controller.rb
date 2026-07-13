class Account::SettingsController < ApplicationController
  before_action :set_account

  def show
    set_settings_dashboard
  end

  private
    def set_account
      @account = Current.account
    end

    def set_settings_dashboard
      @invoice_sources = InvoiceSource.available_sources_for(@account)
    end
end

class Account::SettingsController < ApplicationController
  before_action :set_account
  before_action :set_invoice_sources

  def show; end

  def update
    if @account.update(account_params)
      redirect_to account_settings_path(script_name: @account.slug),
        notice: "Customer segment rules saved. Refresh segments to apply them."
    else
      flash.delete(:notice)
      flash.now[:alert] = @account.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  private
    def set_account
      @account = Current.account
    end

    def set_invoice_sources
      @invoice_sources = InvoiceSource.available_sources_for(@account)
    end

    def account_params
      params.expect(account: Account::PayerSegment::RULE_ATTRIBUTES)
    end
end

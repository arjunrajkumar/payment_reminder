class Account::SettingsController < ApplicationController
  wrap_parameters :account, include: %i[name]

  before_action :ensure_admin, only: :update
  before_action :set_account

  def show
    respond_to do |format|
      format.html { set_settings_dashboard }
      format.json { @users = account_users }
    end
  end

  def update
    @account.update!(account_params)

    respond_to do |format|
      format.html { redirect_to account_settings_path }
      format.json { head :no_content }
    end
  end

  private
    def set_account
      @account = Current.account
    end

    def account_params
      params.expect(account: %i[name])
    end

    def account_users
      @account.users.active.alphabetically.includes(:identity)
    end

    def set_settings_dashboard
      @invoice_sources = InvoiceSource.available_sources_for(@account)
      @billing_email = Current.user.identity&.email_address
      @currency = @account.invoices.where.not(currency: nil).order(updated_at: :desc).pick(:currency).presence || "USD"
    end
end

class XeroConnectionsController < ApplicationController
  before_action :ensure_xero_configured, only: %i[new create]
  before_action :ensure_xero_approved, only: :create
  before_action :ensure_oauth_state, only: :create
  before_action :set_xero_integration, only: %i[show destroy]

  def new
    session[:xero_oauth_state] = SecureRandom.urlsafe_base64(32)
    redirect_to AccountingIntegrations::Xero::OauthClient.new.authorization_url(state: session[:xero_oauth_state]), allow_other_host: true
  end

  def create
    adapter = Current.account.accounting_integrations.build(provider: :xero).provider_adapter
    @accounting_integration = adapter.connect!(code: params.require(:code))
    adapter.sync_invoices!
    session.delete(:xero_oauth_state)

    redirect_to invoices_path, notice: "Xero connected."
  rescue AccountingIntegrations::Xero::OauthClient::Error => error
    handle_xero_error(error)
  end

  def show
  end

  def destroy
    @accounting_integration&.disconnect!
    redirect_to root_path, notice: "Xero disconnected."
  end

  private

  def ensure_xero_configured
    unless AccountingIntegrations::Xero::Configuration.new.configured?
      redirect_to root_path, alert: "Xero credentials are not configured."
    end
  end

  def ensure_xero_approved
    redirect_to root_path, alert: "Xero connection was not approved." if params[:error].present?
  end

  def ensure_oauth_state
    redirect_to root_path, alert: "Xero connection could not be verified." unless valid_oauth_state?
  end

  def set_xero_integration
    if accounting_integration = Current.account.accounting_integrations.xero.connected.first
      @accounting_integration = accounting_integration
    else
      redirect_to root_path, alert: "Connect Xero first."
    end
  end

  def valid_oauth_state?
    session[:xero_oauth_state].present? && ActiveSupport::SecurityUtils.secure_compare(
      session[:xero_oauth_state],
      params[:state].to_s
    )
  end

  def handle_xero_error(error)
    redirect_to root_path, alert: "Xero connection failed: #{error.message}"
  end
end

class XeroConnectionsController < ApplicationController
  before_action :ensure_xero_configured, only: %i[new create]
  before_action :ensure_xero_approved, only: :create
  before_action :ensure_oauth_state, only: :create
  before_action :set_xero_connection, only: %i[show destroy]

  def new
    session[:xero_oauth_state] = SecureRandom.urlsafe_base64(32)
    redirect_to Xero::OauthClient.new.authorization_url(state: session[:xero_oauth_state]), allow_other_host: true
  end

  def create
    XeroConnection.from_oauth!(code: params.require(:code))
    session.delete(:xero_oauth_state)

    redirect_to xero_connection_path, notice: "Xero connected."
  rescue Xero::OauthClient::Error => error
    handle_xero_error(error)
  end

  def show
    return if @xero_connection

    redirect_to root_path, alert: "Connect Xero first."
  end

  def destroy
    @xero_connection&.destroy!
    redirect_to root_path, notice: "Xero disconnected."
  end

  private

  def ensure_xero_configured
    redirect_to root_path, alert: "Xero credentials are not configured." unless Xero::Configuration.new.configured?
  end

  def ensure_xero_approved
    redirect_to root_path, alert: "Xero connection was not approved." if params[:error].present?
  end

  def ensure_oauth_state
    redirect_to root_path, alert: "Xero connection could not be verified." unless valid_oauth_state?
  end

  def set_xero_connection
    @xero_connection = XeroConnection.current
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

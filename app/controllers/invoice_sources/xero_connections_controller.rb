module InvoiceSources
  class XeroConnectionsController < ApplicationController
    before_action :ensure_xero_configured, only: %i[new create]
    before_action :ensure_xero_approved, only: :create
    before_action :ensure_oauth_state, only: :create
    before_action :set_xero_source, only: :destroy

    def new
      session[:xero_oauth_state] = SecureRandom.urlsafe_base64(32)
      redirect_to InvoiceSources::Xero::OauthClient.new.authorization_url(state: session[:xero_oauth_state]), allow_other_host: true
    end

    def create
      @invoice_source = Current.account.invoice_sources.find_or_initialize_by(provider: :xero)
      @invoice_source.connect!(code: params.require(:code))
      @invoice_source.sync_invoices!
      session.delete(:xero_oauth_state)

      redirect_to invoices_path, notice: "Xero connected."
    rescue InvoiceSources::Xero::OauthClient::Error => error
      handle_xero_error(error)
    end

    def destroy
      @invoice_source&.disconnect!
      redirect_to account_settings_path, notice: "Xero disconnected."
    end

    private
      def ensure_xero_configured
        unless InvoiceSources::Xero::Configuration.new.configured?
          redirect_to root_path, alert: "Xero credentials are not configured."
        end
      end

      def ensure_xero_approved
        redirect_to root_path, alert: "Xero connection was not approved." if params[:error].present?
      end

      def ensure_oauth_state
        redirect_to root_path, alert: "Xero connection could not be verified." unless valid_oauth_state?
      end

      def set_xero_source
        if invoice_source = InvoiceSource.connected_for_provider(Current.account, :xero)
          @invoice_source = invoice_source
        else
          redirect_to new_xero_connection_path, alert: "Connect Xero first."
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
end

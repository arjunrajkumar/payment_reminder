module InvoiceSources
  class StripeConnectionsController < ApplicationController
    before_action :ensure_stripe_configured, only: %i[new create]
    before_action :ensure_stripe_approved, only: :create
    before_action :ensure_oauth_state, only: :create
    before_action :set_stripe_source, only: %i[show destroy]

    def new
      session[:stripe_oauth_state] = SecureRandom.urlsafe_base64(32)
      redirect_to InvoiceSources::Stripe::OauthClient.new.authorization_url(state: session[:stripe_oauth_state]), allow_other_host: true
    end

    def create
      @invoice_source = Current.account.invoice_sources.find_or_initialize_by(provider: :stripe)
      @invoice_source.connect!(code: params.require(:code))
      @invoice_source.sync_invoices!
      session.delete(:stripe_oauth_state)

      redirect_to invoices_path, notice: "Stripe connected."
    rescue InvoiceSources::Stripe::OauthClient::Error => error
      handle_stripe_error(error)
    end

    def show
    end

    def destroy
      @invoice_source&.disconnect!
      redirect_to root_path, notice: "Stripe disconnected."
    end

    private
      def ensure_stripe_configured
        unless InvoiceSources::Stripe::Configuration.new.configured?
          redirect_to root_path, alert: "Stripe credentials are not configured."
        end
      end

      def ensure_stripe_approved
        redirect_to root_path, alert: "Stripe connection was not approved." if params[:error].present?
      end

      def ensure_oauth_state
        redirect_to root_path, alert: "Stripe connection could not be verified." unless valid_oauth_state?
      end

      def set_stripe_source
        if invoice_source = InvoiceSource.connected_for_provider(Current.account, :stripe)
          @invoice_source = invoice_source
        else
          redirect_to new_stripe_connection_path, alert: "Connect Stripe first."
        end
      end

      def valid_oauth_state?
        session[:stripe_oauth_state].present? && ActiveSupport::SecurityUtils.secure_compare(
          session[:stripe_oauth_state],
          params[:state].to_s
        )
      end

      def handle_stripe_error(error)
        redirect_to root_path, alert: "Stripe connection failed: #{error.message}"
      end
  end
end

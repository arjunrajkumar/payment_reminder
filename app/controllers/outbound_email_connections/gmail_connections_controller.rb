module OutboundEmailConnections
  class GmailConnectionsController < ApplicationController
    before_action :ensure_google_configured, only: %i[new create]
    before_action :ensure_google_approved, only: :create
    before_action :ensure_oauth_state, only: :create
    before_action :set_connection, only: %i[destroy test]

    def new
      nonce = SecureRandom.urlsafe_base64(32)
      session[:gmail_oauth_nonce] = nonce
      state = OutboundEmailConnection::Gmail::OauthState.issue(account: Current.account, nonce:)

      redirect_to oauth_client.authorization_url(
        state:,
        redirect_uri: gmail_callback_url(script_name: nil)
      ), allow_other_host: true
    end

    def create
      token_data = oauth_client.exchange_code(
        code: params.require(:code),
        redirect_uri: gmail_callback_url(script_name: nil)
      )
      profile = oauth_client.userinfo(access_token: token_data.fetch("access_token"))
      connection = Current.account.outbound_email_connection ||
        Current.account.build_outbound_email_connection(provider: :gmail, connected_email: profile.fetch("email"))

      connection.connect_gmail!(
        email: profile.fetch("email"),
        name: profile["name"],
        access_token: token_data.fetch("access_token"),
        refresh_token: token_data["refresh_token"],
        expires_at: Time.current + token_data.fetch("expires_in").to_i.seconds,
        scopes: token_data.fetch("scope", "").split
      )

      redirect_to account_settings_path(script_name: Current.account.slug), notice: "Gmail connected."
    rescue KeyError, ActiveRecord::RecordInvalid, OutboundEmailConnection::Errors::Error => error
      log_connection_error(error)
      redirect_to account_settings_path(script_name: Current.account.slug),
        alert: "Gmail connection failed: #{error.message}"
    ensure
      session.delete(:gmail_oauth_nonce)
    end

    def destroy
      @connection.disconnect!
      redirect_to account_settings_path(script_name: Current.account.slug), notice: "Gmail disconnected."
    end

    def test
      mail_message = Mail.new(
        to: Current.identity.email_address,
        subject: "PaymentReminder Gmail connection test",
        body: "Your PaymentReminder invoice reminder connection is working."
      )
      OutboundEmailConnection::Delivery.new(
        account: Current.account,
        connection: @connection
      ).deliver(mail_message)

      redirect_to account_settings_path(script_name: Current.account.slug), notice: "Test email sent."
    rescue OutboundEmailConnection::Errors::Error => error
      redirect_to account_settings_path(script_name: Current.account.slug),
        alert: "Test email failed: #{error.message}"
    end

    private
      def ensure_google_configured
        return if gmail_configuration.configured?

        redirect_to account_settings_path(script_name: Current.account.slug),
          alert: "Google credentials are not configured."
      end

      def ensure_google_approved
        return if params[:error].blank?

        session.delete(:gmail_oauth_nonce)
        redirect_to account_settings_path(script_name: Current.account.slug),
          alert: "Gmail connection was not approved."
      end

      def ensure_oauth_state
        valid_state = request_account_matches_current? && OutboundEmailConnection::Gmail::OauthState.valid?(
          params[:state],
          account: Current.account,
          nonce: session[:gmail_oauth_nonce]
        )
        session.delete(:gmail_oauth_nonce)
        return if valid_state

        redirect_to account_settings_path(script_name: Current.account.slug),
          alert: "Gmail connection could not be verified."
      end

      def request_account_matches_current?
        request_account_id = request.env["paidjar.external_account_id"]
        request_account_id.nil? || request_account_id == Current.account.external_account_id
      end

      def set_connection
        @connection = Current.account.outbound_email_connection
        return if @connection.present?

        redirect_to new_gmail_connection_path(script_name: Current.account.slug),
          alert: "Connect Gmail first."
      end

      def oauth_client
        @oauth_client ||= OutboundEmailConnection::Gmail::OauthClient.new(config: gmail_configuration)
      end

      def gmail_configuration
        @gmail_configuration ||= OutboundEmailConnection::Gmail::Configuration.new
      end

      def log_connection_error(error)
        Rails.logger.error(
          "outbound_email.gmail_connection_failed " \
            "account_id=#{Current.account.id} error=#{error.class} message=#{error.message}"
        )
      end
  end
end

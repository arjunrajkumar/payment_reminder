module Xero::OauthFlow
  extend ActiveSupport::Concern

  class Error < StandardError; end

  private
    def start_xero_oauth(flow:, redirect_uri:, scopes:)
      browser_nonce = SecureRandom.urlsafe_base64(32)
      oidc_nonce = SecureRandom.urlsafe_base64(32)
      session[oauth_attempt_key(flow)] = {
        "browser_nonce" => browser_nonce,
        "oidc_nonce" => oidc_nonce
      }
      state = Xero::OauthState.issue(flow:, browser_nonce:)

      redirect_to xero_oauth_client.authorization_url(
        state:,
        nonce: oidc_nonce,
        redirect_uri:,
        scopes:
      ), allow_other_host: true
    end

    def finish_xero_oauth(flow:, redirect_uri:, include_connections:)
      attempt = session.delete(oauth_attempt_key(flow))&.with_indifferent_access
      valid_state = attempt.present? && Xero::OauthState.valid?(
        params[:state],
        flow:,
        browser_nonce: attempt[:browser_nonce]
      )
      raise Error, "Xero sign-in could not be verified." unless valid_state
      raise Error, "Xero access was not approved." if params[:error].present?

      code = params[:code].to_s.presence
      raise Error, "Xero did not return an authorization code." if code.blank?

      Xero::Authorization.new.complete!(
        code:,
        redirect_uri:,
        nonce: attempt[:oidc_nonce],
        include_connections:
      )
    end

    def xero_oauth_client
      @xero_oauth_client ||= InvoiceSources::Xero::OauthClient.new(config: xero_configuration)
    end

    def xero_configuration
      @xero_configuration ||= InvoiceSources::Xero::Configuration.new
    end

    def ensure_xero_identity_configured
      return if xero_configuration.configured?

      redirect_to xero_configuration_failure_path,
        alert: "Xero sign-in is not configured yet. Use email instead."
    end

    def oauth_attempt_key(flow)
      "xero_#{flow}_oauth_attempt"
    end
end

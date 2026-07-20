module Xero
  class SessionsController < ApplicationController
    include Xero::OauthFlow

    disallow_account_scope
    require_unauthenticated_access
    rate_limit to: 10, within: 3.minutes, only: :create,
      with: -> { redirect_to new_session_path, alert: "Try again later." }
    before_action :ensure_xero_identity_configured

    layout "public"

    def new
      start_xero_oauth(
        flow: :signin,
        redirect_uri: xero_configuration.session_redirect_uri,
        scopes: xero_configuration.identity_scopes
      )
    end

    def create
      authorization = finish_xero_oauth(
        flow: :signin,
        redirect_uri: xero_configuration.session_redirect_uri,
        include_connections: false
      )
      external_identity = ExternalIdentity.xero.find_by!(subject: authorization.identity.subject)

      start_new_session_for(external_identity.identity)
      redirect_to after_authentication_url
    rescue ActiveRecord::RecordNotFound
      redirect_to new_session_path,
        alert: "We couldn't find a Xero-linked account. Try signing up or use your email."
    rescue Xero::OauthFlow::Error, Xero::Authorization::Error => error
      redirect_to new_session_path, alert: error.message
    end

    private
      def xero_configuration_failure_path
        new_session_path
      end
  end
end

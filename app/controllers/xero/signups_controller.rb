module Xero
  class SignupsController < ApplicationController
    include Xero::OauthFlow

    disallow_account_scope
    require_unauthenticated_access
    rate_limit to: 10, within: 3.minutes, only: :create,
      with: -> { redirect_to new_signup_path, alert: "Try again later." }
    before_action :ensure_xero_identity_configured

    layout "public"

    def new
      start_xero_oauth(
        flow: :signup,
        redirect_uri: xero_configuration.signup_redirect_uri,
        scopes: xero_configuration.scopes
      )
    end

    def create
      authorization = finish_xero_oauth(
        flow: :signup,
        redirect_uri: xero_configuration.signup_redirect_uri,
        include_connections: true
      )
      signup = Xero::Signup.new(authorization:).complete!

      start_new_session_for(signup.identity)
      queue_initial_refresh(signup.invoice_source)
      redirect_to account_settings_url(script_name: signup.account.slug),
        notice: "Your Xero account is connected."
    rescue Xero::Signup::ExistingIdentityError => error
      redirect_to new_session_path, alert: error.message
    rescue Xero::OauthFlow::Error, Xero::Authorization::Error,
      Xero::Signup::ConnectionError, Xero::Signup::TenantConflictError => error
      redirect_to new_signup_path, alert: error.message
    rescue ActiveRecord::ActiveRecordError, KeyError => error
      Rails.error.report(error, severity: :error)
      redirect_to new_signup_path,
        alert: "We couldn't create your account from Xero. Please try again."
    end

    private
      def xero_configuration_failure_path
        new_signup_path
      end

      def queue_initial_refresh(invoice_source)
        InvoiceSources::RefreshJob.perform_later(invoice_source)
      rescue ActiveJob::EnqueueError => error
        Rails.error.report(error, severity: :error)
      end
  end
end

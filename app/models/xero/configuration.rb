module Xero
  class Configuration
    DEFAULT_SCOPES = %w[
      openid
      profile
      email
      accounting.invoices.read
      offline_access
    ].freeze

    attr_reader :env

    def initialize(env: ENV)
      @env = env
    end

    def configured?
      client_id.present? && client_secret.present?
    end

    def client_id
      env["XERO_CLIENT_ID"].presence || Rails.application.credentials.dig(:xero, :client_id)
    end

    def client_secret
      env["XERO_CLIENT_SECRET"].presence || Rails.application.credentials.dig(:xero, :client_secret)
    end

    def scopes
      env["XERO_SCOPES"].presence || DEFAULT_SCOPES.join(" ")
    end

    def redirect_uri
      env["XERO_REDIRECT_URI"].presence ||
        Rails.application.credentials.dig(:xero, :redirect_uri) ||
        "http://localhost:3000/xero/callback"
    end

    def authorization_uri
      URI("https://login.xero.com/identity/connect/authorize")
    end

    def token_uri
      URI("https://identity.xero.com/connect/token")
    end

    def connections_uri
      URI("https://api.xero.com/connections")
    end

    def userinfo_uri
      URI("https://api.xero.com/identity/connect/userinfo")
    end
  end
end

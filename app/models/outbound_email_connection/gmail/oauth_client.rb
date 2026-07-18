require "json"
require "net/http"
require "openssl"
require "uri"

class OutboundEmailConnection::Gmail::OauthClient
  attr_reader :config

  def initialize(config: OutboundEmailConnection::Gmail::Configuration.new)
    @config = config
  end

  def authorization_url(state:, redirect_uri:)
    uri = config.authorization_uri.dup
    uri.query = Rack::Utils.build_query(
      response_type: "code",
      client_id: config.client_id,
      redirect_uri:,
      scope: config.scopes.join(" "),
      state:,
      access_type: "offline",
      prompt: "consent",
      include_granted_scopes: true
    )
    uri.to_s
  end

  def exchange_code(code:, redirect_uri:)
    post_token(
      grant_type: "authorization_code",
      code:,
      redirect_uri:
    )
  end

  def refresh_token(refresh_token:)
    post_token(grant_type: "refresh_token", refresh_token:)
  end

  def userinfo(access_token:)
    request = Net::HTTP::Get.new(config.userinfo_uri)
    request["Authorization"] = "Bearer #{access_token}"
    request_json(config.userinfo_uri, request)
  end

  private
    def post_token(form)
      request = Net::HTTP::Post.new(config.token_uri)
      request["Content-Type"] = "application/x-www-form-urlencoded"
      request.set_form_data(form.merge(client_id: config.client_id, client_secret: config.client_secret))

      request_json(config.token_uri, request)
    end

    def request_json(uri, request)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end
      payload = JSON.parse(response.body.presence || "{}")

      return payload if response.is_a?(Net::HTTPSuccess)

      error_message = payload["error_description"] || payload["error"] || response.message
      raise error_class_for(response, payload), error_message
    rescue JSON::ParserError
      raise OutboundEmailConnection::Errors::PermanentDeliveryError, "Google returned an invalid response."
    rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => error
      raise OutboundEmailConnection::Errors::TemporaryDeliveryError, "Google request failed: #{error.message}"
    end

    def authentication_failure?(response, payload)
      response.is_a?(Net::HTTPUnauthorized) ||
        (response.is_a?(Net::HTTPBadRequest) && payload["error"].in?(%w[invalid_grant invalid_client]))
    end

    def error_class_for(response, payload)
      return OutboundEmailConnection::Errors::AuthenticationError if authentication_failure?(response, payload)
      return OutboundEmailConnection::Errors::TemporaryDeliveryError if response.code.to_i == 429 || response.code.to_i >= 500

      OutboundEmailConnection::Errors::PermanentDeliveryError
    end
end

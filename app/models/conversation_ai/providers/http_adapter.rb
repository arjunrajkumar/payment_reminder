require "net/http"

class ConversationAi::Providers::HttpAdapter
  CONNECT_TIMEOUT = 10
  READ_TIMEOUT = 45
  WRITE_TIMEOUT = 15

  def initialize(api_key:, model:, endpoint:)
    @api_key = api_key
    @model = model
    @endpoint = URI(endpoint)
  end

  private
    attr_reader :api_key, :model, :endpoint

    def post_json(payload, headers:, sanitized_request:)
      request = Net::HTTP::Post.new(endpoint)
      headers.each { |key, value| request[key] = value }
      request.body = JSON.generate(payload)
      http = Net::HTTP.new(endpoint.host, endpoint.port)
      http.use_ssl = endpoint.scheme == "https"
      http.open_timeout = CONNECT_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = WRITE_TIMEOUT
      http.max_retries = 0 if http.respond_to?(:max_retries=)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = http.request(request)
      latency = (
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
      ).round
      [ response, latency ]
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error => error
      raise network_error(
        "timeout",
        error,
        sanitized_request:,
        possible_duplicate_cost: true
      )
    rescue OpenSSL::SSL::SSLError, SocketError, EOFError,
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH => error
      raise network_error("connection", error, sanitized_request:)
    end

    def parse_json(response, sanitized_request:)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError => error
      raise ConversationAi::ProviderError.new(
        category: "malformed_output",
        message: "Provider returned invalid JSON: #{error.class}",
        response_status: response.code.to_i,
        provider_request_id: request_id(response),
        sanitized_request:,
        sanitized_response: ConversationAi::AuditSnapshot.bounded(
          "body" => response.body.to_s
        )
      )
    end

    def network_error(
      category,
      error,
      sanitized_request:,
      possible_duplicate_cost: false
    )
      ConversationAi::ProviderError.new(
        category:,
        message: "#{error.class}: #{error.message}",
        sanitized_request:,
        possible_duplicate_cost:
      )
    end

    def raise_http_error!(response, body, sanitized_request:)
      status = response.code.to_i
      provider_message = body.dig("error", "message").to_s
      provider_code = body.dig("error", "code").to_s
      category = case status
      when 400, 422
        provider_code.match?(/model|not_found/i) ||
          provider_message.match?(/model|structured output/i) ?
            "unsupported_model" :
            "invalid_request"
      when 401 then "authentication"
      when 402 then "billing"
      when 403 then "permission"
      when 408, 409 then "server_error"
      when 429 then "rate_limited"
      when 529 then "overloaded"
      when 500..599 then "server_error"
      else "unknown"
      end
      raise ConversationAi::ProviderError.new(
        category:,
        message: provider_message.presence || "Provider HTTP #{status}",
        response_status: status,
        provider_request_id: request_id(response),
        retry_after_seconds: ConversationAi::AuditSnapshot.retry_after(response),
        sanitized_request:,
        sanitized_response: ConversationAi::AuditSnapshot.bounded(body)
      )
    end

    def request_id(response)
      response["x-request-id"].presence || response["request-id"].presence
    end
end

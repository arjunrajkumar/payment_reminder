class ConversationAi::Providers::Anthropic < ConversationAi::Providers::HttpAdapter
  ADAPTER_VERSION = "anthropic_messages_v1"
  ENDPOINT = "https://api.anthropic.com/v1/messages"
  API_VERSION = "2023-06-01"

  def initialize(api_key:, model:)
    super(api_key:, model:, endpoint: ENDPOINT)
  end

  def analyze(request:)
    payload = {
      "model" => model,
      "max_tokens" => request.maximum_output_tokens,
      "system" => request.system_instructions,
      "messages" => [
        {
          "role" => "user",
          "content" => request.untrusted_context
        }
      ],
      "output_config" => {
        "format" => {
          "type" => "json_schema",
          "schema" => request.json_schema
        }
      }
    }
    sanitized_request = ConversationAi::AuditSnapshot.bounded(payload)
    response, latency = post_json(
      payload,
      sanitized_request:,
      headers: {
        "x-api-key" => api_key,
        "anthropic-version" => API_VERSION,
        "Content-Type" => "application/json"
      }
    )
    body = parse_json(response, sanitized_request:)
    raise_http_error!(response, body, sanitized_request:) unless response.is_a?(Net::HTTPSuccess)
    if body["stop_reason"] == "refusal"
      raise ConversationAi::ProviderError.new(
        category: "refusal",
        message: "Provider refused the request.",
        response_status: response.code.to_i,
        provider_request_id: request_id(response),
        sanitized_request:,
        sanitized_response: ConversationAi::AuditSnapshot.bounded(body),
        returned_model: body["model"]
      )
    end
    unless body["stop_reason"] == "end_turn"
      raise ConversationAi::ProviderError.new(
        category: "malformed_output",
        message: "Provider response was truncated or incomplete.",
        response_status: response.code.to_i,
        provider_request_id: request_id(response),
        sanitized_request:,
        sanitized_response: ConversationAi::AuditSnapshot.bounded(body),
        returned_model: body["model"]
      )
    end
    output_text = Array(body["content"])
      .find { |content| content["type"] == "text" }
      &.fetch("text", nil)
    structured = JSON.parse(output_text.to_s)
    usage = body["usage"].to_h
    input_tokens = usage["input_tokens"]
    output_tokens = usage["output_tokens"]
    ConversationAi::ProviderResult.new(
      structured_output: structured,
      provider: "anthropic",
      provider_request_id: request_id(response),
      requested_model: model,
      returned_model: body["model"],
      input_tokens:,
      cached_input_tokens: usage["cache_read_input_tokens"],
      output_tokens:,
      total_tokens: input_tokens && output_tokens ? input_tokens + output_tokens : nil,
      latency_ms: latency,
      sanitized_request:,
      sanitized_response: ConversationAi::AuditSnapshot.bounded(body),
      provider_metadata: {
        "message_id" => body["id"],
        "stop_reason" => body["stop_reason"],
        "stop_sequence" => body["stop_sequence"]
      }.compact
    )
  rescue JSON::ParserError => error
    raise ConversationAi::ProviderError.new(
      category: "malformed_output",
      message: "Structured output was not valid JSON: #{error.class}",
      sanitized_request: sanitized_request || {},
      sanitized_response: ConversationAi::AuditSnapshot.bounded(body || {})
    )
  end
end

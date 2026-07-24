class ConversationAi::Providers::OpenAi < ConversationAi::Providers::HttpAdapter
  ADAPTER_VERSION = "openai_responses_v1"
  ENDPOINT = "https://api.openai.com/v1/responses"
  API_VERSION = "responses_v1"

  def initialize(api_key:, model:)
    super(api_key:, model:, endpoint: ENDPOINT)
  end

  def analyze(request:)
    payload = {
      "model" => model,
      "input" => [
        {
          "role" => "system",
          "content" => [
            { "type" => "input_text", "text" => request.system_instructions }
          ]
        },
        {
          "role" => "user",
          "content" => [
            { "type" => "input_text", "text" => request.untrusted_context }
          ]
        }
      ],
      "text" => {
        "format" => {
          "type" => "json_schema",
          "name" => "conversation_interpretation",
          "description" => "A bounded shadow interpretation of one inbound email.",
          "schema" => request.json_schema,
          "strict" => true
        }
      },
      "max_output_tokens" => request.maximum_output_tokens,
      "store" => false,
      "safety_identifier" => request.safety_identifier
    }
    sanitized_request = ConversationAi::AuditSnapshot.bounded(payload)
    response, latency = post_json(
      payload,
      sanitized_request:,
      headers: {
        "Authorization" => "Bearer #{api_key}",
        "Content-Type" => "application/json",
        "X-Client-Request-Id" => request.application_request_id
      }
    )
    body = parse_json(response, sanitized_request:)
    raise_http_error!(response, body, sanitized_request:) unless response.is_a?(Net::HTTPSuccess)
    refusal = body.fetch("output", []).flat_map { |item| Array(item["content"]) }
      .find { |content| content["type"] == "refusal" }
    if refusal
      raise ConversationAi::ProviderError.new(
        category: "refusal",
        message: refusal["refusal"].presence || "Provider refused the request.",
        response_status: response.code.to_i,
        provider_request_id: request_id(response),
        sanitized_request:,
        sanitized_response: ConversationAi::AuditSnapshot.bounded(body),
        returned_model: body["model"]
      )
    end
    if body["status"] != "completed"
      raise ConversationAi::ProviderError.new(
        category: "malformed_output",
        message: "Provider response was incomplete.",
        response_status: response.code.to_i,
        provider_request_id: request_id(response),
        sanitized_request:,
        sanitized_response: ConversationAi::AuditSnapshot.bounded(body),
        returned_model: body["model"]
      )
    end
    output_text = body.fetch("output", []).flat_map { |item| Array(item["content"]) }
      .find { |content| content["type"] == "output_text" }
      &.fetch("text", nil)
    structured = JSON.parse(output_text.to_s)
    usage = body["usage"].to_h
    ConversationAi::ProviderResult.new(
      structured_output: structured,
      provider: "openai",
      provider_request_id: request_id(response) || body["id"],
      requested_model: model,
      returned_model: body["model"],
      input_tokens: usage["input_tokens"],
      cached_input_tokens: usage.dig("input_tokens_details", "cached_tokens"),
      output_tokens: usage["output_tokens"],
      total_tokens: usage["total_tokens"],
      latency_ms: latency,
      sanitized_request:,
      sanitized_response: ConversationAi::AuditSnapshot.bounded(body),
      provider_metadata: {
        "response_id" => body["id"],
        "status" => body["status"]
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

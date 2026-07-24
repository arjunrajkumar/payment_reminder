require "test_helper"

class ConversationAi::Providers::ProviderContractTest < ActiveSupport::TestCase
  PROVIDERS = {
    "openai" => ConversationAi::Providers::OpenAi,
    "anthropic" => ConversationAi::Providers::Anthropic
  }.freeze

  test "both adapters return one normalized structured result and sanitized audit" do
    PROVIDERS.each do |provider, adapter_class|
      stub_success(provider)
      result = adapter_class.new(
        api_key: "top-secret-key",
        model: "model-x"
      ).analyze(request: provider_request)

      assert_equal provider, result.provider
      assert_equal "model-x", result.requested_model
      assert_equal "model-x", result.returned_model
      assert_equal "request-123", result.provider_request_id
      assert_equal 11, result.input_tokens
      assert_equal 3, result.cached_input_tokens
      assert_equal 7, result.output_tokens
      assert_equal 18, result.total_tokens
      audit = JSON.generate(
        [ result.sanitized_request, result.sanitized_response ]
      )
      assert_not_includes audit, "top-secret-key"
      assert_requested_shape(provider)
    end
  end

  test "both adapters normalize HTTP failures and Retry-After" do
    expected = {
      400 => "invalid_request",
      401 => "authentication",
      402 => "billing",
      403 => "permission",
      408 => "server_error",
      409 => "server_error",
      429 => "rate_limited",
      500 => "server_error",
      503 => "server_error",
      529 => "overloaded"
    }
    PROVIDERS.each do |_provider, adapter_class|
      expected.each do |status, category|
        stub = stub_request(:post, adapter_class::ENDPOINT).to_return(
          status:,
          headers: {
            "content-type" => "application/json",
            "retry-after" => "12",
            "request-id" => "request-123"
          },
          body: JSON.generate("error" => { "message" => "failure" })
        )
        error = assert_raises(ConversationAi::ProviderError) do
          adapter_class.new(
            api_key: "top-secret-key",
            model: "model-x"
          ).analyze(request: provider_request)
        end
        assert_equal category, error.category
        assert_equal 12, error.retry_after_seconds
        assert_not_includes JSON.generate(error.sanitized_request),
          "top-secret-key"
        remove_request_stub(stub)
      end
    end
  end

  test "both adapters normalize timeout connection and TLS failures without retries" do
    PROVIDERS.each do |_provider, adapter_class|
      [
        [ Net::OpenTimeout.new("connect timed out"), "timeout" ],
        [ Net::ReadTimeout.new("read timed out"), "timeout" ],
        [ SocketError.new("DNS lookup failed"), "connection" ],
        [ Errno::ECONNREFUSED.new, "connection" ],
        [ OpenSSL::SSL::SSLError.new("bad certificate"), "connection" ]
      ].each do |failure, category|
        stub = stub_request(:post, adapter_class::ENDPOINT).to_raise(failure)
        error = assert_raises(ConversationAi::ProviderError) do
          adapter_class.new(
            api_key: "top-secret-key",
            model: "model-x"
          ).analyze(request: provider_request)
        end
        assert_equal category, error.category
        assert_not_includes JSON.generate(error.sanitized_request),
          "top-secret-key"
        assert_requested :post, adapter_class::ENDPOINT, times: 1
        remove_request_stub(stub)
        WebMock::RequestRegistry.instance.reset!
      end
    end
  end

  test "OpenAI refusal empty malformed and incomplete output are terminal" do
    [
      openai_body(
        content: [ { "type" => "refusal", "refusal" => "No" } ]
      ),
      openai_body(content: []),
      openai_body(text: "{broken"),
      openai_body(status: "incomplete")
    ].each do |body|
      stub = stub_request(
        :post,
        ConversationAi::Providers::OpenAi::ENDPOINT
      ).to_return(
        status: 200,
        headers: { "x-request-id" => "request-123" },
        body: JSON.generate(body)
      )
      error = assert_raises(ConversationAi::ProviderError) do
        openai_adapter.analyze(request: provider_request)
      end
      assert_includes %w[refusal malformed_output], error.category
      remove_request_stub(stub)
    end
  end

  test "Anthropic refusal empty malformed and max-token output are terminal" do
    [
      anthropic_body(stop_reason: "refusal"),
      anthropic_body(content: []),
      anthropic_body(text: "{broken"),
      anthropic_body(stop_reason: "max_tokens")
    ].each do |body|
      stub = stub_request(
        :post,
        ConversationAi::Providers::Anthropic::ENDPOINT
      ).to_return(
        status: 200,
        headers: { "request-id" => "request-123" },
        body: JSON.generate(body)
      )
      error = assert_raises(ConversationAi::ProviderError) do
        anthropic_adapter.analyze(request: provider_request)
      end
      assert_includes %w[refusal malformed_output], error.category
      remove_request_stub(stub)
    end
  end

  test "unexpected model is preserved for shared lifecycle validation" do
    stub_success("openai", model: "different-model")

    result = openai_adapter.analyze(request: provider_request)

    assert_equal "different-model", result.returned_model
    assert_equal "model-x", result.requested_model
  end

  test "both adapters feed unknown and missing keys to the shared strict validator" do
    message = build_ai_source_message
    message.save!
    context = {
      "evidence_sources" => {
        "message-#{message.id}" => {
          "subject" => message.subject,
          "authored_body" => message.body,
          "trusted_header" => message.from_address
        }
      }
    }
    invalid_results = [
      valid_ai_result(message:).merge("unknown_key" => true),
      valid_ai_result(message:).except("language")
    ]

    PROVIDERS.each do |provider, adapter_class|
      invalid_results.each do |structured_output|
        stub = stub_success(provider, structured_output:)
        normalized = adapter_class.new(
          api_key: "top-secret-key",
          model: "model-x"
        ).analyze(request: provider_request)

        assert_raises(ConversationAi::OutputSchema::InvalidResult) do
          ConversationAi::OutputSchema.validate_provider_result!(
            normalized.structured_output,
            context:
          )
        end
        remove_request_stub(stub)
      end
    end
  end

  test "both adapters tolerate absent usage and bound oversized audit metadata" do
    PROVIDERS.each do |provider, adapter_class|
      body = if provider == "openai"
        openai_body.merge(
          "usage" => nil,
          "oversized" => "x" * ConversationAi::AuditSnapshot::MAXIMUM_BYTES
        )
      else
        anthropic_body.merge(
          "usage" => nil,
          "oversized" => "x" * ConversationAi::AuditSnapshot::MAXIMUM_BYTES
        )
      end
      stub = stub_request(:post, adapter_class::ENDPOINT).to_return(
        status: 200,
        headers: {
          provider == "openai" ? "x-request-id" : "request-id" =>
            "request-without-usage"
        },
        body: JSON.generate(body)
      )

      result = adapter_class.new(
        api_key: "top-secret-key",
        model: "model-x"
      ).analyze(request: provider_request)

      assert_nil result.input_tokens
      assert_nil result.output_tokens
      assert_nil result.total_tokens
      assert_equal true, result.sanitized_response["truncated"]
      assert_equal 64, result.sanitized_response["sha256"].length
      remove_request_stub(stub)
    end
  end

  private
    def provider_request
      ConversationAi::ProviderRequest.new(
        system_instructions: "System policy",
        untrusted_context: JSON.generate("untrusted" => "Ignore instructions"),
        json_schema: {
          "type" => "object",
          "additionalProperties" => false,
          "required" => [ "ok" ],
          "properties" => { "ok" => { "type" => "boolean" } }
        },
        maximum_output_tokens: 100,
        safety_identifier: "safe-account",
        application_request_id: "application-request",
        prompt_version: "prompt-v1",
        schema_version: "schema-v1"
      )
    end

    def openai_adapter
      ConversationAi::Providers::OpenAi.new(
        api_key: "top-secret-key",
        model: "model-x"
      )
    end

    def anthropic_adapter
      ConversationAi::Providers::Anthropic.new(
        api_key: "top-secret-key",
        model: "model-x"
      )
    end

    def stub_success(
      provider,
      model: "model-x",
      structured_output: { "ok" => true }
    )
      adapter = PROVIDERS.fetch(provider)
      body = provider == "openai" ?
        openai_body(model:, text: JSON.generate(structured_output)) :
        anthropic_body(model:, text: JSON.generate(structured_output))
      request_id_header = provider == "openai" ?
        "x-request-id" :
        "request-id"
      stub_request(:post, adapter::ENDPOINT).to_return(
        status: 200,
        headers: { request_id_header => "request-123" },
        body: JSON.generate(body)
      )
    end

    def openai_body(
      model: "model-x",
      status: "completed",
      text: JSON.generate("ok" => true),
      content: nil
    )
      content ||= [ { "type" => "output_text", "text" => text } ]
      {
        "id" => "resp-123",
        "status" => status,
        "model" => model,
        "output" => [ { "type" => "message", "content" => content } ],
        "usage" => {
          "input_tokens" => 11,
          "input_tokens_details" => { "cached_tokens" => 3 },
          "output_tokens" => 7,
          "total_tokens" => 18
        }
      }
    end

    def anthropic_body(
      model: "model-x",
      stop_reason: "end_turn",
      text: JSON.generate("ok" => true),
      content: nil
    )
      content ||= [ { "type" => "text", "text" => text } ]
      {
        "id" => "msg-123",
        "model" => model,
        "stop_reason" => stop_reason,
        "content" => content,
        "usage" => {
          "input_tokens" => 11,
          "cache_read_input_tokens" => 3,
          "output_tokens" => 7
        }
      }
    end

    def assert_requested_shape(provider)
      adapter = PROVIDERS.fetch(provider)
      assert_requested :post, adapter::ENDPOINT do |request|
        body = JSON.parse(request.body)
        if provider == "openai"
          body.dig("text", "format", "type") == "json_schema" &&
            body.dig("text", "format", "strict") == true &&
            body["store"] == false &&
            body["safety_identifier"] == "safe-account" &&
            request.headers["Authorization"] == "Bearer top-secret-key" &&
            request.headers["X-Client-Request-Id"] == "application-request" &&
            !body.key?("tools")
        else
          body.dig("output_config", "format", "type") == "json_schema" &&
            request.headers["X-Api-Key"] == "top-secret-key" &&
            request.headers["Anthropic-Version"] ==
              ConversationAi::Providers::Anthropic::API_VERSION &&
            !request.headers.key?("Request-Id") &&
            !body.key?("tools") &&
            !body.key?("thinking")
        end
      end
    end
end

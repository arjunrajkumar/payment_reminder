ConversationAi::ProviderResult = Data.define(
  :structured_output,
  :provider,
  :provider_request_id,
  :requested_model,
  :returned_model,
  :input_tokens,
  :cached_input_tokens,
  :output_tokens,
  :total_tokens,
  :latency_ms,
  :sanitized_request,
  :sanitized_response,
  :provider_metadata
)

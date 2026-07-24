ConversationAi::ProviderRequest = Data.define(
  :system_instructions,
  :untrusted_context,
  :json_schema,
  :maximum_output_tokens,
  :safety_identifier,
  :application_request_id,
  :prompt_version,
  :schema_version
)

class ConversationAi::ProviderError < StandardError
  CATEGORIES = %w[
    invalid_request authentication permission billing rate_limited overloaded
    timeout connection server_error refusal malformed_output unsupported_model unknown
  ].freeze
  RETRYABLE = %w[rate_limited overloaded timeout connection server_error].freeze

  attr_reader :category,
    :response_status,
    :provider_request_id,
    :retry_after_seconds,
    :sanitized_request,
    :sanitized_response,
    :returned_model,
    :provider_metadata,
    :possible_duplicate_cost

  def initialize(
    category:,
    message:,
    response_status: nil,
    provider_request_id: nil,
    retry_after_seconds: nil,
    sanitized_request: {},
    sanitized_response: {},
    returned_model: nil,
    provider_metadata: {},
    possible_duplicate_cost: false
  )
    @category = category.to_s.presence_in(CATEGORIES) || "unknown"
    @response_status = response_status
    @provider_request_id = provider_request_id
    @retry_after_seconds = retry_after_seconds
    @sanitized_request = sanitized_request
    @sanitized_response = sanitized_response
    @returned_model = returned_model
    @provider_metadata = provider_metadata
    @possible_duplicate_cost = possible_duplicate_cost
    super(message.to_s.truncate(2_000))
  end

  def retryable?
    category.in?(RETRYABLE)
  end
end

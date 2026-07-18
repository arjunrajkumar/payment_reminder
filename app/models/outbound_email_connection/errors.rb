module OutboundEmailConnection::Errors
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class TemporaryDeliveryError < Error; end
  class PermanentDeliveryError < Error; end
end

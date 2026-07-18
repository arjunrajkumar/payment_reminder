require "google/apis/gmail_v1"
require "json"

class OutboundEmailConnection::Gmail::Delivery
  def initialize(account:, connection:, service: Google::Apis::GmailV1::GmailService.new)
    @account = account
    @connection = connection
    @service = service
  end

  def deliver(mail_message)
    validate_connection!
    connection.refresh_gmail_access_token_if_needed!
    apply_sender!(mail_message)

    service.authorization = connection.access_token
    response = service.send_user_message(
      "me",
      Google::Apis::GmailV1::Message.new(raw: mail_message.encoded)
    )
    response.id
  rescue OutboundEmailConnection::Errors::AuthenticationError
    raise
  rescue Google::Apis::AuthorizationError => error
    connection.mark_errored!(error)
    raise OutboundEmailConnection::Errors::AuthenticationError, error.message
  rescue Google::Apis::RateLimitError,
    Google::Apis::RequestTimeOutError,
    Google::Apis::ServerError,
    Google::Apis::TransmissionError => error
    raise OutboundEmailConnection::Errors::TemporaryDeliveryError, error.message
  rescue Google::Apis::ClientError => error
    classify_client_error!(error)
  end

  private
    attr_reader :account, :connection, :service

    def validate_connection!
      unless connection.account_id == account.id && connection.active?
        raise OutboundEmailConnection::Errors::PermanentDeliveryError, "Outbound email connection is not active for this account."
      end

      unless connection.sender_matches?(account.invoice_reminder_from_email)
        raise OutboundEmailConnection::Errors::PermanentDeliveryError, "Sender address does not match the connected Gmail account."
      end
    end

    def apply_sender!(mail_message)
      sender_name = account.invoice_reminder_from_name.presence || account.name
      mail_message[:from] = Mail::Address.new(connection.connected_email).tap do |address|
        address.display_name = sender_name
      end.to_s
    end

    def classify_client_error!(error)
      reasons = gmail_error_reasons(error)

      if reasons.intersect?(%w[rateLimitExceeded userRateLimitExceeded quotaExceeded backendError])
        raise OutboundEmailConnection::Errors::TemporaryDeliveryError, error.message
      end

      if error.status_code == 403 && reasons.intersect?(%w[authError insufficientPermissions forbidden])
        connection.mark_errored!(error)
        raise OutboundEmailConnection::Errors::AuthenticationError, error.message
      end

      raise OutboundEmailConnection::Errors::PermanentDeliveryError, error.message
    end

    def gmail_error_reasons(error)
      payload = JSON.parse(error.body.presence || "{}")
      Array(payload.dig("error", "errors")).filter_map { |item| item["reason"] }
    rescue JSON::ParserError
      []
    end
end

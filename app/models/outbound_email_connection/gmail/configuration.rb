class OutboundEmailConnection::Gmail::Configuration
  SCOPES = [
    "email",
    "profile",
    OutboundEmailConnection::Gmailable::SEND_SCOPE
  ].freeze

  def client_id
    Rails.application.credentials.dig(:google, :client_id)
  end

  def client_secret
    Rails.application.credentials.dig(:google, :client_secret)
  end

  def configured?
    client_id.present? && client_secret.present?
  end

  def scopes
    SCOPES
  end

  def authorization_uri
    URI("https://accounts.google.com/o/oauth2/v2/auth")
  end

  def token_uri
    URI("https://oauth2.googleapis.com/token")
  end

  def userinfo_uri
    URI("https://www.googleapis.com/oauth2/v2/userinfo")
  end
end

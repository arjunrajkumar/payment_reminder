module OutboundEmailConnection::Gmailable
  extend ActiveSupport::Concern

  SEND_SCOPE = "https://www.googleapis.com/auth/gmail.send"
  TOKEN_REFRESH_BUFFER = 5.minutes

  included do
    validate :gmail_send_scope_granted, if: :active_gmail_connection?
  end

  def connect_gmail!(email:, name:, access_token:, refresh_token:, expires_at:, scopes:)
    existing_refresh_token = self.refresh_token if connected_email.blank? || connected_email.casecmp?(email.to_s)

    transaction do
      assign_attributes(
        provider: :gmail,
        connected_email: email,
        provider_display_name: name,
        access_token:,
        refresh_token: refresh_token.presence || existing_refresh_token,
        token_expires_at: expires_at,
        scopes: Array(scopes),
        status: :active,
        last_error: nil
      )
      save!
      account.update!(
        invoice_reminder_from_email: connected_email,
        invoice_reminder_from_name: account.invoice_reminder_from_name.presence || account.name
      )
    end

    self
  end

  def refresh_gmail_access_token_if_needed!(oauth_client: OutboundEmailConnection::Gmail::OauthClient.new)
    return access_token unless gmail_token_refresh_needed?

    token_data = oauth_client.refresh_token(refresh_token:)
    update!(
      access_token: token_data.fetch("access_token"),
      refresh_token: token_data["refresh_token"].presence || refresh_token,
      token_expires_at: Time.current + token_data.fetch("expires_in").to_i.seconds,
      scopes: token_data["scope"].to_s.split.presence || scopes,
      last_error: nil
    )
    access_token
  rescue OutboundEmailConnection::Errors::AuthenticationError => error
    mark_errored!(error)
    raise
  end

  private
    def active_gmail_connection?
      gmail? && active?
    end

    def gmail_token_refresh_needed?
      token_expires_at.blank? || token_expires_at <= TOKEN_REFRESH_BUFFER.from_now
    end

    def gmail_send_scope_granted
      return if scopes.include?(SEND_SCOPE)

      errors.add(:scopes, "must include Gmail send access")
    end
end

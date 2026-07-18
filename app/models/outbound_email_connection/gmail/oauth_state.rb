class OutboundEmailConnection::Gmail::OauthState
  PURPOSE = "outbound_email_gmail_oauth"
  EXPIRES_IN = 15.minutes

  class << self
    def issue(account:, nonce:)
      verifier.generate(
        { "account_id" => account.id, "nonce" => nonce },
        expires_in: EXPIRES_IN,
        purpose: PURPOSE
      )
    end

    def valid?(token, account:, nonce:)
      payload = verifier.verify(token, purpose: PURPOSE)

      payload.fetch("account_id") == account.id &&
        ActiveSupport::SecurityUtils.secure_compare(payload.fetch("nonce"), nonce.to_s)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError
      false
    end

    private
      def verifier
        Rails.application.message_verifier(:outbound_email_oauth)
      end
  end
end

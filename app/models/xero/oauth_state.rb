module Xero
  class OauthState
    PURPOSE = "xero_identity_oauth"
    EXPIRES_IN = 15.minutes

    class << self
      def issue(flow:, browser_nonce:)
        verifier.generate(
          { "flow" => flow.to_s, "browser_nonce" => browser_nonce },
          expires_in: EXPIRES_IN,
          purpose: PURPOSE
        )
      end

      def valid?(token, flow:, browser_nonce:)
        payload = verifier.verify(token, purpose: PURPOSE)

        ActiveSupport::SecurityUtils.secure_compare(payload.fetch("flow"), flow.to_s) &&
          ActiveSupport::SecurityUtils.secure_compare(payload.fetch("browser_nonce"), browser_nonce.to_s)
      rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError
        false
      end

      private
        def verifier
          Rails.application.message_verifier(:xero_identity_oauth)
        end
    end
  end
end

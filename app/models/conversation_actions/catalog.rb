class ConversationActions::Catalog
  class InvalidAction < ConversationActions::Error; end

  TEMPLATE_VERSION = 1
  MAXIMUM_NON_FACTUAL_TEXT_LENGTH = 500

  Definition = Data.define(
    :action_type,
    :invoice_required,
    :customer_required,
    :source_message_required,
    :authorization,
    :provider_refresh_required,
    :local_mutation,
    :reply_kind,
    :allowed_during_hold,
    :escalation_only,
    :arguments,
    :proposed_reply
  ) do
    def reply?
      reply_kind.present?
    end
  end

  DEFINITIONS = {
    "record_payment_promise" => {
      invoice_required: true,
      customer_required: true,
      source_message_required: true,
      authorization: :member,
      provider_refresh_required: true,
      local_mutation: true,
      reply_kind: :payment_promise_acknowledgement,
      allowed_during_hold: true,
      escalation_only: false
    },
    "answer_due_date" => {
      invoice_required: true,
      customer_required: true,
      source_message_required: true,
      authorization: :member,
      provider_refresh_required: true,
      local_mutation: false,
      reply_kind: :due_date_answer,
      allowed_during_hold: true,
      escalation_only: false
    },
    "answer_payment_status" => {
      invoice_required: true,
      customer_required: true,
      source_message_required: true,
      authorization: :member,
      provider_refresh_required: true,
      local_mutation: false,
      reply_kind: :payment_status_answer,
      allowed_during_hold: true,
      escalation_only: false
    },
    "answer_outstanding_amount" => {
      invoice_required: true,
      customer_required: true,
      source_message_required: true,
      authorization: :member,
      provider_refresh_required: true,
      local_mutation: false,
      reply_kind: :outstanding_amount_answer,
      allowed_during_hold: true,
      escalation_only: false
    },
    "resend_invoice" => {
      invoice_required: true,
      customer_required: true,
      source_message_required: true,
      authorization: :member,
      provider_refresh_required: true,
      local_mutation: false,
      reply_kind: :invoice_resend,
      allowed_during_hold: true,
      escalation_only: false
    },
    "add_recipient" => {
      invoice_required: true,
      customer_required: true,
      source_message_required: true,
      authorization: :dynamic,
      provider_refresh_required: false,
      local_mutation: true,
      reply_kind: :recipient_update_acknowledgement,
      allowed_during_hold: true,
      escalation_only: false
    },
    "open_dispute" => {
      invoice_required: true,
      customer_required: true,
      source_message_required: true,
      authorization: :member,
      provider_refresh_required: false,
      local_mutation: true,
      reply_kind: :dispute_acknowledgement,
      allowed_during_hold: true,
      escalation_only: false
    },
    "other" => {
      invoice_required: false,
      customer_required: false,
      source_message_required: false,
      authorization: :member,
      provider_refresh_required: false,
      local_mutation: false,
      reply_kind: nil,
      allowed_during_hold: true,
      escalation_only: true
    }
  }.freeze

  class << self
    def validate!(action_type:, arguments:, proposed_reply:)
      action_type = action_type.to_s
      attributes = DEFINITIONS[action_type] ||
        raise(InvalidAction, "This action type is not supported.")
      parsed_arguments = validate_arguments!(action_type, arguments)
      validate_proposed_reply!(proposed_reply)

      Definition.new(
        action_type:,
        arguments: parsed_arguments,
        proposed_reply: proposed_reply.deep_stringify_keys,
        **attributes
      )
    end

    private
      def validate_arguments!(action_type, arguments)
        invalid!("Structured arguments must be a JSON object.") unless
          arguments.is_a?(Hash)
        invalid!("Structured argument keys must be strings.") unless
          arguments.keys.all?(String)

        case action_type
        when "record_payment_promise"
          exact_keys!(arguments, required: %w[promised_on])
          {
            "promised_on" => strict_iso_date!(
              arguments.fetch("promised_on"),
              name: "promised_on"
            )
          }
        when "add_recipient"
          exact_keys!(arguments, required: %w[email mode])
          {
            "email" => strict_email!(arguments.fetch("email")),
            "mode" => strict_mode!(arguments.fetch("mode"))
          }
        else
          exact_keys!(arguments, required: [])
          {}
        end
      end

      def validate_proposed_reply!(proposed_reply)
        invalid!("Proposed reply must be a JSON object.") unless
          proposed_reply.is_a?(Hash)
        version = proposed_reply["template_version"]
        if version.present? && version != TEMPLATE_VERSION
          invalid!("The reply template version is not supported.")
        end
        placeholders = proposed_reply["placeholders"]
        return if placeholders.nil?
        invalid!("Reply placeholders must be a JSON object.") unless
          placeholders.is_a?(Hash)
        unknown = placeholders.keys - %w[greeting closing]
        invalid!("The reply contains an unsupported placeholder.") if unknown.any?
        placeholders.each_value do |value|
          invalid!("Reply wording must be plain bounded text.") unless
            value.is_a?(String) &&
              value.length <= MAXIMUM_NON_FACTUAL_TEXT_LENGTH &&
              !value.match?(/[\r\n]/)
        end
      end

      def exact_keys!(arguments, required:)
        missing = required - arguments.keys
        unknown = arguments.keys - required
        invalid!("Required structured arguments are missing.") if missing.any?
        invalid!("Unknown structured arguments are not allowed.") if unknown.any?
      end

      def strict_iso_date!(value, name:)
        invalid!("#{name} must be an ISO date.") unless
          value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        date = Date.iso8601(value)
        if date < Date.new(1000, 1, 1) || date > Date.new(9999, 12, 30)
          invalid!("#{name} is outside the supported date range.")
        end
        date
      rescue Date::Error
        invalid!("#{name} must be a valid ISO date.")
      end

      def strict_email!(value)
        invalid!("Email must be a string.") unless value.is_a?(String)
        email = value.strip.downcase
        invalid!("Email is invalid.") if
          email.blank? ||
            email.length > 254 ||
            email.match?(/[\r\n]/) ||
            !email.match?(URI::MailTo::EMAIL_REGEXP)
        email
      end

      def strict_mode!(value)
        invalid!("Recipient mode must be a string.") unless value.is_a?(String)
        return value if value.in?(%w[future_reminders cc_current_reply])

        invalid!("Recipient mode is not supported.")
      end

      def invalid!(message)
        raise InvalidAction, message
      end
  end
end

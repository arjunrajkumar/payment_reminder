class ConversationAi::Planner
  VERSION = "shadow_planner_v1"
  CONFIDENCE_THRESHOLD_BPS = 8_500
  SUPPORTED_LANGUAGES = %w[en en-US en-GB].freeze
  MAPPING = {
    "payment_promise" => "record_payment_promise",
    "question_due_date" => "answer_due_date",
    "question_payment_status" => "answer_payment_status",
    "question_outstanding_amount" => "answer_outstanding_amount",
    "resend_invoice" => "resend_invoice",
    "add_recipient" => "add_recipient",
    "dispute" => "open_dispute",
    "other_requires_person" => "other"
  }.freeze

  Result = Data.define(
    :decision,
    :proposed_action_type,
    :arguments,
    :proposed_reply,
    :user_facing_summary,
    :planner_reason_codes,
    :confidence_bps
  )

  class << self
    def plan(interpretation)
      new(interpretation).plan
    end
  end

  def initialize(interpretation)
    @interpretation = interpretation
    @result = interpretation.structured_result.deep_stringify_keys
  end

  def plan
    return no_action("automatic_reply") if interpretation.message_kind == "automatic_reply"
    return no_action("unrelated") if interpretation.message_kind == "unrelated"
    return human_review("unreliable_authored_content") unless authored_content_reliable?
    return human_review("unsupported_language") unless supported_language?
    return human_review("requires_human") if interpretation.requires_human?
    return human_review("low_overall_confidence") if
      interpretation.overall_confidence_bps < CONFIDENCE_THRESHOLD_BPS

    intents = result.fetch("intents")
    return human_review("no_intent") if intents.empty?
    return human_review("multiple_intents") unless intents.one?

    intent = intents.first
    return human_review("low_intent_confidence") if
      intent.fetch("confidence_bps") < CONFIDENCE_THRESHOLD_BPS

    action_type = MAPPING.fetch(intent.fetch("type"))
    arguments = arguments_for(intent)
    proposed_reply = catalog_reply(result.fetch("proposed_reply"))
    ConversationActions::Catalog.validate!(
      action_type:,
      arguments:,
      proposed_reply:
    )
    Result.new(
      decision: "propose_action",
      proposed_action_type: action_type,
      arguments:,
      proposed_reply:,
      user_facing_summary: interpretation.summary,
      planner_reason_codes: [ "validated_single_intent" ],
      confidence_bps: [
        interpretation.overall_confidence_bps,
        intent.fetch("confidence_bps")
      ].min
    )
  rescue ConversationActions::Catalog::InvalidAction,
    ArgumentError,
    Date::Error => error
    human_review("catalog_validation_failed", error.class.name)
  end

  private
    attr_reader :interpretation, :result

    def authored_content_reliable?
      !interpretation.authored_content_warnings.intersect?(%w[
        no_authored_content body_parse_failed attachment_only
      ])
    end

    def supported_language?
      interpretation.language.in?(SUPPORTED_LANGUAGES)
    end

    def arguments_for(intent)
      values = intent.fetch("values")
      case intent.fetch("type")
      when "payment_promise"
        promised_on = Date.iso8601(values.fetch("promised_on"))
        received_date = interpretation.source_message.received_at
          .in_time_zone(interpretation.account.time_zone)
          .to_date
        raise ArgumentError, "promise date is in the past" if promised_on < received_date
        raise ArgumentError, "promise date is too far away" if promised_on > received_date + 1.year
        require_authored_evidence!(intent, values.fetch("original_date_text"))
        { "promised_on" => promised_on.iso8601 }
      when "add_recipient"
        email = values.fetch("email").to_s.strip.downcase
        mode = values.fetch("mode")
        require_authored_or_header_evidence!(intent, email)
        {
          "email" => email,
          "mode" => mode == "permanent" ? "future_reminders" : mode
        }
      when "dispute"
        summary = values.fetch("dispute_summary").to_s
        raise ArgumentError, "dispute summary is missing" if summary.blank?
        require_authored_evidence!(intent, summary)
        {}
      else
        {}
      end
    end

    def require_authored_evidence!(intent, value)
      valid = intent.fetch("evidence").any? do |evidence|
        evidence["field"] == "authored_body" &&
          evidence["quote"].include?(value.to_s)
      end
      raise ArgumentError, "value lacks authored evidence" unless valid
    end

    def require_authored_or_header_evidence!(intent, value)
      valid = intent.fetch("evidence").any? do |evidence|
        evidence["field"].in?(%w[authored_body trusted_header]) &&
          evidence["quote"].downcase.include?(value)
      end
      raise ArgumentError, "recipient lacks authorized evidence" unless valid
    end

    def catalog_reply(reply)
      placeholders = {}
      placeholders["greeting"] = reply["greeting"] if reply["greeting"].present?
      placeholders["closing"] = reply["closing"] if reply["closing"].present?
      {
        "template_version" => ConversationActions::Catalog::TEMPLATE_VERSION,
        "placeholders" => placeholders
      }
    end

    def human_review(*reasons)
      Result.new(
        decision: "human_review",
        proposed_action_type: nil,
        arguments: {},
        proposed_reply: {},
        user_facing_summary: interpretation.summary.presence || "A person should review this email.",
        planner_reason_codes: reasons,
        confidence_bps: interpretation.overall_confidence_bps
      )
    end

    def no_action(reason)
      Result.new(
        decision: "no_action",
        proposed_action_type: nil,
        arguments: {},
        proposed_reply: {},
        user_facing_summary: interpretation.summary.presence || "No collection action is suggested.",
        planner_reason_codes: [ reason ],
        confidence_bps: interpretation.overall_confidence_bps
      )
    end
end

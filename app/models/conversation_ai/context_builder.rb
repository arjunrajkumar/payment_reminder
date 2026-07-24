class ConversationAi::ContextBuilder
  MAXIMUM_RECENT_MESSAGES = 8
  MAXIMUM_EXCERPT_LENGTH = 1_500

  Result = Data.define(
    :snapshot,
    :authored_content,
    :warnings,
    :input_digest,
    :guidance_revision
  )

  class << self
    def build(message:, work_unit:, guidance_revision: nil)
      new(
        message:,
        work_unit:,
        guidance_revision:
      ).build
    end
  end

  def initialize(message:, work_unit:, guidance_revision:)
    @message = message
    @work_unit = work_unit
    @guidance_revision = guidance_revision
  end

  def build
    extracted = ConversationMessages::AuthoredContent.extract(message)
    source_key = opaque_key(message)
    snapshot = {
      "account_key" => Digest::SHA256.hexdigest("account:#{message.account_id}"),
      "account_timezone" => message.account.time_zone,
      "source_key" => source_key,
      "source_received_at" => message.received_at&.iso8601,
      "source_subject" => message.subject.to_s.first(500),
      "untrusted_authored_content" => extracted.body,
      "trusted_headers" => trusted_headers,
      "invoice_identifier" => message.invoice&.number.to_s.first(100).presence,
      "customer_name" => message.conversation.canonical.customer&.name.to_s
        .first(200)
        .presence,
      "recent_untrusted_messages" => bounded_recent_messages,
      "approved_customer_guidance" => approved_guidance,
      "extraction_warnings" => extracted.warnings,
      "evidence_sources" => {
        source_key => {
          "subject" => message.subject.to_s.first(500),
          "authored_body" => extracted.body,
          "trusted_header" => trusted_headers.values.compact.flatten.join("\n")
        }
      }
    }.compact
    canonical = JSON.generate(deep_sort(snapshot))
    Result.new(
      snapshot:,
      authored_content: extracted,
      warnings: extracted.warnings,
      input_digest: Digest::SHA256.hexdigest(canonical),
      guidance_revision:
    )
  end

  private
    attr_reader :message, :work_unit, :guidance_revision

    def bounded_recent_messages
      message.account.conversation_messages
        .where(id: work_unit.message_ids)
        .where.not(id: message.id)
        .order(
          Arel.sql("COALESCE(received_at, sent_at, created_at) DESC"),
          id: :desc
        )
        .limit(MAXIMUM_RECENT_MESSAGES)
        .to_a
        .reverse
        .map do |recent|
          extracted = ConversationMessages::AuthoredContent.extract(recent)
          {
            "key" => opaque_key(recent),
            "direction" => recent.direction,
            "occurred_at" => recent.occurred_at.iso8601,
            "subject" => recent.subject.to_s.first(300),
            "untrusted_excerpt" => extracted.body.first(MAXIMUM_EXCERPT_LENGTH)
          }
        end
    end

    def trusted_headers
      {
        "from" => message.from_address,
        "to" => Array(message.to_addresses).first(20),
        "cc" => Array(message.cc_addresses).first(20),
        "reply_to" => Array(message.reply_to_addresses).first(20),
        "internet_message_id" => message.internet_message_id,
        "in_reply_to" => Array(message.in_reply_to_message_ids).first(20),
        "references" => Array(message.reference_message_ids).last(20)
      }.compact
    end

    def approved_guidance
      return {} unless guidance_revision&.status_active?

      {
        "revision_key" => "guidance-#{guidance_revision.id}",
        "digest" => Digest::SHA256.hexdigest(
          JSON.generate(deep_sort(guidance_revision.structured_guidance))
        ),
        "style_only_untrusted_guidance" => guidance_revision.structured_guidance
      }
    end

    def opaque_key(record)
      "message-#{record.id}"
    end

    def deep_sort(value)
      case value
      when Hash
        value.keys.sort.index_with { |key| deep_sort(value[key]) }
      when Array
        value.map { |item| deep_sort(item) }
      else
        value
      end
    end
end

class ConversationMessages::AuthoredContent
  MAXIMUM_LENGTH = 12_000
  Result = Data.define(:body, :warnings, :truncated, :reliable) do
    alias_method :truncated?, :truncated
    alias_method :reliable?, :reliable
  end

  QUOTE_BOUNDARIES = [
    /^On .+wrote:\s*$/i,
    /^-{2,}\s*Original Message\s*-{2,}\s*$/i,
    /^_{5,}\s*$/,
    /^From:\s.+$/i
  ].freeze
  SIGNATURE_BOUNDARIES = [
    /^--\s*$/,
    /^Sent from my (?:iPhone|iPad|Android).*/i,
    /^Get Outlook for (?:iOS|Android).*/i
  ].freeze

  class << self
    def extract(message)
      new(message).extract
    end
  end

  def initialize(message)
    @message = message
  end

  def extract
    warnings = Array(message.provider_metadata["parse_warnings"]).map(&:to_s)
    body = message.body.to_s.encode(
      Encoding::UTF_8,
      invalid: :replace,
      undef: :replace,
      replace: "�"
    )
    warnings << "invalid_encoding_replaced" if body.include?("�")
    if html?(body)
      body = body.gsub(
        /<\s*\/?\s*(?:p|div|br|li|tr|blockquote)\b[^>]*>/i,
        "\n"
      )
      body = ActionView::Base.full_sanitizer.sanitize(body)
      warnings << "html_normalized"
    end
    body = normalize_controls(body)
    authored = isolate_authored_lines(body, warnings)
    authored = authored.strip
    truncated = authored.length > MAXIMUM_LENGTH
    authored = authored.first(MAXIMUM_LENGTH) if truncated
    warnings << "authored_content_truncated" if truncated
    warnings << "no_authored_content" if authored.blank?
    reliable = authored.present? &&
      !warnings.intersect?(%w[
        body_parse_failed attachment_only no_authored_content
      ])

    Result.new(
      body: authored,
      warnings: warnings.uniq.freeze,
      truncated:,
      reliable:
    )
  end

  private
    attr_reader :message

    def html?(body)
      body.match?(/<\s*(?:html|body|div|p|br|table|blockquote)\b/i)
    end

    def normalize_controls(body)
      body
        .gsub("\r\n", "\n")
        .gsub("\r", "\n")
        .gsub(/[\u202A-\u202E\u2066-\u2069]/, "")
        .delete("\u0000")
    end

    def isolate_authored_lines(body, warnings)
      lines = body.lines
      boundary = lines.index do |line|
        QUOTE_BOUNDARIES.any? { |pattern| line.strip.match?(pattern) }
      end
      if boundary
        before_boundary = lines.first(boundary)
        bottom_reply = bottom_posted_reply(lines.drop(boundary + 1))
        lines = if before_boundary.join.strip.present?
          before_boundary
        else
          bottom_reply
        end
        warnings << "quoted_history_removed"
      end
      lines = lines.reject do |line|
        quoted = line.lstrip.start_with?(">")
        warnings << "quoted_lines_removed" if quoted
        quoted
      end
      signature = lines.index do |line|
        SIGNATURE_BOUNDARIES.any? { |pattern| line.strip.match?(pattern) }
      end
      if signature
        lines = lines.first(signature)
        warnings << "signature_removed"
      end
      lines.join
    end

    def bottom_posted_reply(lines)
      last_quoted_line = lines.rindex { |line| line.lstrip.start_with?(">") }
      return [] unless last_quoted_line

      lines.drop(last_quoted_line + 1)
    end
end

require "test_helper"

class ConversationMessages::AuthoredContentTest < ActiveSupport::TestCase
  test "extracts top replies and removes Gmail quotes and signatures" do
    message = build_ai_source_message(
      body: <<~BODY
        I will pay Friday.

        Sent from my iPhone
        On Thu, Jul 23, 2026 at 9:00 AM Billing wrote:
        > I will pay next month.
      BODY
    )

    result = ConversationMessages::AuthoredContent.extract(message)

    assert_equal "I will pay Friday.", result.body
    assert_predicate result, :reliable?
    assert_includes result.warnings, "quoted_history_removed"
    assert_includes result.warnings, "signature_removed"
  end

  test "handles Outlook history HTML invalid encoding and Unicode controls" do
    message = build_ai_source_message(
      body: "<p>\u202EPlease be concise.</p><p>-----Original Message-----</p><p>old</p>"
    )

    result = ConversationMessages::AuthoredContent.extract(message)

    assert_equal "Please be concise.", result.body
    assert_includes result.warnings, "html_normalized"
    assert_includes result.warnings, "quoted_history_removed"
  end

  test "extracts a safely delimited bottom-posted reply" do
    message = build_ai_source_message(
      body: <<~BODY
        On Thu, Jul 23, 2026 at 9:00 AM Billing wrote:
        > Please pay invoice INV-1.
        > It remains outstanding.

        I will pay on Friday.
      BODY
    )

    result = ConversationMessages::AuthoredContent.extract(message)

    assert_equal "I will pay on Friday.", result.body
    assert_predicate result, :reliable?
    assert_includes result.warnings, "quoted_history_removed"
  end

  test "marks quoted-only and attachment-only input unreliable" do
    quoted = build_ai_source_message(body: "> I will pay Friday.")
    attachment = build_ai_source_message(
      body: "",
      provider_metadata: {
        "label_ids" => [ "INBOX" ],
        "parse_warnings" => [ "attachment_only" ]
      }
    )

    quoted_result = ConversationMessages::AuthoredContent.extract(quoted)
    attachment_result = ConversationMessages::AuthoredContent.extract(attachment)

    assert_not_predicate quoted_result, :reliable?
    assert_includes quoted_result.warnings, "no_authored_content"
    assert_not_predicate attachment_result, :reliable?
    assert_includes attachment_result.warnings, "attachment_only"
  end

  test "bounds very long authored content without changing the source" do
    original = "a" * (ConversationMessages::AuthoredContent::MAXIMUM_LENGTH + 50)
    message = build_ai_source_message(body: original)

    result = ConversationMessages::AuthoredContent.extract(message)

    assert_predicate result, :truncated?
    assert_equal ConversationMessages::AuthoredContent::MAXIMUM_LENGTH,
      result.body.length
    assert_equal original, message.body
  end
end

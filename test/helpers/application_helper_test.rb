require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  def parse(html)
    Nokogiri::HTML::DocumentFragment.parse(html)
  end

  test "page title tag without page title or account" do
    Current.account = nil

    assert_select parse(page_title_tag), "title", text: "PaymentReminder"
  end

  test "page title tag with page title" do
    Current.account = nil
    @page_title = "Account Settings"

    assert_select parse(page_title_tag), "title", text: "Account Settings | PaymentReminder"
  end

  test "page title tag with page title and account" do
    Current.account = accounts(:paid_jar)
    @page_title = "Account Settings"

    assert_select parse(page_title_tag), "title", text: "Account Settings | PaymentReminder"
  ensure
    Current.reset
  end

  test "notification finalization has a specific safe label and outcome counts" do
    event = ConversationEvent.new(
      kind: :invoice_reminder_notifications_finalized,
      metadata: {
        "delivered_count" => 2,
        "uncertain_count" => 1,
        "failed_count" => 3,
        "canceled_count" => 4,
        "recipient_email" => "private@example.com",
        "last_error_message" => "raw SMTP secret"
      }
    )

    assert_equal "Reminder notifications finalized",
      conversation_event_label(event)
    detail = conversation_event_detail(event)
    assert_equal(
      "Delivered: 2 · Unconfirmed: 1 · Failed: 3 · Canceled: 4",
      detail
    )
    assert_not_includes detail, "private@example.com"
    assert_not_includes detail, "raw SMTP secret"
  end
end

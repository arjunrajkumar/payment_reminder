require "test_helper"

class ConversationActions::CatalogTest < ActiveSupport::TestCase
  test "accepts only the exact payment promise contract" do
    definition = ConversationActions::Catalog.validate!(
      action_type: "record_payment_promise",
      arguments: { "promised_on" => "2026-08-05" },
      proposed_reply: {}
    )

    assert_equal Date.new(2026, 8, 5), definition.arguments.fetch("promised_on")
  end

  test "rejects unknown keys, wrong types, malformed values, and unsupported actions" do
    invalid_requests = [
      [ "record_payment_promise", {}, {} ],
      [ "record_payment_promise", { "promised_on" => "2026-08-05", "amount" => "1.00" }, {} ],
      [ "record_payment_promise", { "promised_on" => 20260805 }, {} ],
      [ "record_payment_promise", { "promised_on" => "05/08/2026" }, {} ],
      [ "add_recipient", { "email" => "person@example.com", "mode" => "bcc" }, {} ],
      [ "add_recipient", { "email" => "victim@example.com\r\nBcc: attacker@example.com", "mode" => "cc_current_reply" }, {} ],
      [ "unsupported", {}, {} ]
    ]

    invalid_requests.each do |action_type, arguments, proposed_reply|
      assert_raises ConversationActions::Catalog::InvalidAction do
        ConversationActions::Catalog.validate!(
          action_type:,
          arguments:,
          proposed_reply:
        )
      end
    end
  end

  test "rejects unknown reply placeholders and template versions" do
    [
      { "template_version" => 99 },
      { "template_version" => 1, "placeholders" => { "invoice_amount" => "false" } }
    ].each do |proposed_reply|
      assert_raises ConversationActions::Catalog::InvalidAction do
        ConversationActions::Catalog.validate!(
          action_type: "answer_due_date",
          arguments: {},
          proposed_reply:
        )
      end
    end
  end
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "mocha/minitest"
require "webmock/minitest"

WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    def conversation_work_unit_token(conversation)
      Conversations::WorkUnitSnapshot.token_for(conversation:)
    end

    def build_ai_source_message(attributes = {})
      invoice = attributes.delete(:invoice) || invoices(:xero_invoice)
      conversation = attributes.delete(:conversation) ||
        Conversation.for_invoice!(invoice:)
      connection = attributes.delete(:email_connection) ||
        email_connections(:paid_jar_gmail)
      ConversationMessage.new(
        {
          account: invoice.account,
          conversation:,
          invoice:,
          email_connection: connection,
          email_connection_generation: connection.credential_generation,
          provider_account_id: connection.provider_account_id,
          provider_message_id: "gmail-ai-#{SecureRandom.hex(8)}",
          provider_thread_id: "gmail-thread-ai",
          direction: :inbound,
          kind: :customer_email,
          status: :received,
          received_at: Time.current,
          from_address: invoice.customer.email,
          to_addresses: [ connection.connected_email ],
          cc_addresses: [],
          bcc_addresses: [],
          reply_to_addresses: [],
          subject: "Re: Invoice #{invoice.number}",
          body: "I will pay on Friday.",
          internet_message_id: "<ai-#{SecureRandom.hex(8)}@example.com>",
          in_reply_to_message_ids: [],
          reference_message_ids: [],
          provider_metadata: {
            "label_ids" => [ "INBOX" ],
            "parse_warnings" => []
          },
          matching_status: :matched,
          matching_method: :invoice_reference,
          review_required: false,
          review_reasons: [],
          automatic: false
        }.merge(attributes)
      )
    end

    def enable_ai_shadow!(account: accounts(:paid_jar), provider: "openai")
      account.update_columns(
        conversation_ai_mode: "shadow",
        conversation_ai_provider: provider,
        conversation_ai_enabled_at: 1.minute.ago
      )
      account.reload
    end

    def valid_ai_result(
      message:,
      intent_type: "payment_promise",
      overall_confidence_bps: 9_000,
      intent_confidence_bps: 9_000,
      values: nil
    )
      values ||= {
        "promised_on" => 2.days.from_now.to_date.iso8601,
        "original_date_text" => "Friday",
        "email" => nil,
        "mode" => nil,
        "dispute_summary" => nil
      }
      {
        "schema_version" => ConversationAi::OutputSchema::VERSION,
        "message_kind" => "customer_request",
        "language" => "en",
        "overall_confidence_bps" => overall_confidence_bps,
        "requires_human" => false,
        "summary" => "Customer promises payment.",
        "concise_rationale" => "The authored reply contains one clear request.",
        "reason_codes" => [],
        "intents" => [
          {
            "type" => intent_type,
            "confidence_bps" => intent_confidence_bps,
            "evidence" => [
              {
                "source_key" => "message-#{message.id}",
                "field" => "authored_body",
                "quote" => intent_type == "payment_promise" ? "Friday" : message.body.first(30),
                "purpose" => "Supports the detected intent."
              }
            ],
            "values" => values
          }
        ],
        "proposed_reply" => {
          "greeting" => "Hello",
          "acknowledgement" => "Thank the customer.",
          "closing" => "Best",
          "tone_hints" => [ "concise" ],
          "outline" => [ "Acknowledge the request." ]
        },
        "feedback_signals" => []
      }
    end
  end
end

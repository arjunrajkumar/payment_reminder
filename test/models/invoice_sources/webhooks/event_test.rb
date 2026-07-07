require "test_helper"

class InvoiceSources::Webhooks::EventTest < ActiveSupport::TestCase
  test "records a webhook event idempotently" do
    attributes = event_attributes(provider_event_id: "evt_123")

    event, created = InvoiceSources::Webhooks::Event.record(attributes)
    duplicate_event, duplicate_created = InvoiceSources::Webhooks::Event.record(attributes)

    assert created
    assert_not duplicate_created
    assert_equal event, duplicate_event
  end

  test "process syncs invoice and marks processed" do
    event = InvoiceSources::Webhooks::Event.create!(event_attributes)

    InvoiceSource.any_instance.expects(:sync_invoice!).with(external_id: "invoice-123")

    event.process!

    assert_predicate event.reload, :processed?
    assert_not_nil event.processed_at
    assert_nil event.last_error
  end

  test "process marks non invoice events ignored" do
    event = InvoiceSources::Webhooks::Event.create!(
      event_attributes(resource_type: "contact", resource_id: "contact-123")
    )

    InvoiceSource.any_instance.expects(:sync_invoice!).never

    event.process!

    assert_predicate event.reload, :ignored?
    assert_not_nil event.processed_at
  end

  test "process stores failure and reraises" do
    event = InvoiceSources::Webhooks::Event.create!(event_attributes)

    InvoiceSource.any_instance.expects(:sync_invoice!).raises(InvoiceSources::Xero::OauthClient::Error, "provider unavailable")

    assert_raises InvoiceSources::Xero::OauthClient::Error do
      event.process!
    end

    assert_predicate event.reload, :failed?
    assert_equal "provider unavailable", event.last_error
  end

  private
    def event_attributes(**overrides)
      {
        invoice_source: invoice_sources(:xero),
        provider: :xero,
        provider_event_id: "xero-event-123",
        event_type: "UPDATE",
        resource_type: "invoice",
        resource_id: "invoice-123",
        occurred_at: Time.zone.local(2026, 7, 7, 10, 0, 0),
        payload: { "event" => { "resourceId" => "invoice-123" } }
      }.merge(overrides)
    end
end

require "test_helper"

class InvoiceSources::Webhooks::ProcessJobTest < ActiveJob::TestCase
  include ActiveJob::TestHelper

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "retries provider sync failures" do
    event = InvoiceSources::Webhooks::Event.create!(
      invoice_source: invoice_sources(:xero),
      provider: :xero,
      provider_event_id: "xero-event-retry",
      event_type: "UPDATE",
      resource_type: "invoice",
      resource_id: "invoice-123",
      occurred_at: Time.zone.local(2026, 7, 7, 10, 0, 0),
      payload: { "event" => { "resourceId" => "invoice-123" } }
    )

    InvoiceSource.any_instance.expects(:sync_invoice!).raises(InvoiceSources::Xero::OauthClient::Error, "provider unavailable")

    assert_enqueued_with(job: InvoiceSources::Webhooks::ProcessJob) do
      InvoiceSources::Webhooks::ProcessJob.perform_now(event)
    end

    assert_predicate event.reload, :failed?
    assert_equal "provider unavailable", event.last_error
  end
end

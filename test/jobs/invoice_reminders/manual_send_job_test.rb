require "test_helper"

class InvoiceReminders::ManualSendJobTest < ActiveJob::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @invoice.account.update!(automatic_invoice_reminders_enabled: false)
    @invoice.update!(synced_at: Time.current)
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).with(@invoice).returns(@invoice)
  end

  test "limits manual delivery concurrency per invoice" do
    first_job = InvoiceReminders::ManualSendJob.new(@invoice.id)
    same_invoice_job = InvoiceReminders::ManualSendJob.new(@invoice.id)
    other_invoice_job = InvoiceReminders::ManualSendJob.new(@invoice.id + 1)

    assert_predicate first_job, :concurrency_limited?
    assert_equal first_job.concurrency_key, same_invoice_job.concurrency_key
    refute_equal first_job.concurrency_key, other_invoice_job.concurrency_key
    assert_equal 1, InvoiceReminders::ManualSendJob.concurrency_limit
  end

  test "delivers and records a manually requested reminder" do
    delivery_result = EmailConnection::Delivery::Result.new(
      provider_message_id: "manual-provider-message",
      provider_thread_id: "manual-provider-thread"
    )
    EmailConnection::Delivery.any_instance.expects(:deliver).returns(delivery_result)

    assert_difference -> { @invoice.conversation_messages.count }, 1 do
      InvoiceReminders::ManualSendJob.perform_now(@invoice.id)
    end

    message = @invoice.conversation_messages.order(:id).last
    assert_predicate message, :kind_manual_reminder?
    assert_predicate message, :status_sent?
    assert_equal "manual-provider-message", message.provider_message_id
    assert_equal "manual-provider-thread", message.provider_thread_id
    assert message.sent_at.present?
  end

  test "records a confirmed provider failure" do
    EmailConnection::Delivery.any_instance.expects(:deliver)
      .raises(EmailConnection::Errors::PermanentDeliveryError, "invalid recipient")

    InvoiceReminders::ManualSendJob.perform_now(@invoice.id)

    message = @invoice.conversation_messages.order(:id).last
    assert_predicate message, :kind_manual_reminder?
    assert_predicate message, :status_failed?
    assert_equal "invalid recipient", message.failure_reason
  end

  test "claims provider delivery and preserves ambiguous uncertainty" do
    EmailConnection::Delivery.any_instance.expects(:deliver)
      .raises(EmailConnection::Errors::AmbiguousDeliveryError, "response lost")

    InvoiceReminders::ManualSendJob.perform_now(@invoice.id)

    message = @invoice.conversation_messages.order(:id).last
    assert_predicate message, :kind_manual_reminder?
    assert_predicate message, :provider_delivery_claimed?
    assert_predicate message, :status_failed?
    assert_predicate message, :delivery_uncertain?
    assert_equal "response lost", message.failure_reason
  end

  test "same job re-entry after sent does not call the provider twice" do
    result = EmailConnection::Delivery::Result.new(
      provider_message_id: "manual-reentry-sent",
      provider_thread_id: "manual-reentry-thread"
    )
    EmailConnection::Delivery.any_instance.expects(:deliver).once.returns(result)
    job = InvoiceReminders::ManualSendJob.new(@invoice.id)

    2.times { job.perform_now }

    messages = @invoice.conversation_messages
      .kind_manual_reminder
      .where(delivery_job_id: job.job_id)
    assert_equal 1, messages.count
    assert_predicate messages.sole, :status_sent?
  end

  test "same job re-entry after uncertain failure does not call the provider twice" do
    EmailConnection::Delivery.any_instance.expects(:deliver).once
      .raises(EmailConnection::Errors::AmbiguousDeliveryError, "response lost")
    job = InvoiceReminders::ManualSendJob.new(@invoice.id)

    2.times { job.perform_now }

    messages = @invoice.conversation_messages
      .kind_manual_reminder
      .where(delivery_job_id: job.job_id)
    assert_equal 1, messages.count
    assert_predicate messages.sole, :delivery_uncertain?
  end

  test "same job re-entry after definite failure does not call the provider twice" do
    EmailConnection::Delivery.any_instance.expects(:deliver).once
      .raises(EmailConnection::Errors::PermanentDeliveryError, "rejected")
    job = InvoiceReminders::ManualSendJob.new(@invoice.id)

    2.times { job.perform_now }

    messages = @invoice.conversation_messages
      .kind_manual_reminder
      .where(delivery_job_id: job.job_id)
    assert_equal 1, messages.count
    assert_predicate messages.sole, :status_failed?
    assert_not_predicate messages.sole, :delivery_uncertain?
  end
end

require "test_helper"

class InvoiceReminders::ManualDeliveryReservationTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @account.update!(automatic_invoice_reminders_enabled: false)
  end

  test "reserves a manual reminder while automatic reminders are disabled" do
    assert_difference -> { @invoice.conversation_messages.count }, 1 do
      @result = reserve
    end

    assert_predicate @result, :reserved?
    assert_equal email_connections(:paid_jar_gmail), @result.connection
    assert_equal Conversation.for_invoice!(invoice: @invoice), @result.message.conversation
    assert_equal "manual_reminder", @result.message.kind
    assert_predicate @result.message, :status_pending?
    assert_equal "manual-reminder-job", @result.message.delivery_job_id
    assert_equal @result.connection, @result.message.email_connection
    assert_equal @result.connection.provider_account_id, @result.message.provider_account_id
    assert_equal @result.connection.credential_generation, @result.message.email_connection_generation
    assert_match(/\A<.+@paymentreminder\.local>\z/, @result.message.internet_message_id)
    assert_equal [ "customer@example.com" ], @result.message.to_addresses
    assert_match(/INV-001/, @result.message.subject)
  end

  test "does not reuse a pending manual reminder after the Gmail identity is replaced" do
    first_result = reserve
    first_result.connection.update!(provider_account_id: "replacement-google-account")

    replacement_result = reserve

    assert_not_predicate replacement_result, :reserved?
    assert_equal "email_connection_replaced", replacement_result.reason
  end

  test "does not reuse a pending manual reminder after the same Gmail identity reconnects" do
    first_result = reserve
    first_result.connection.increment!(:credential_generation)

    replacement_result = reserve

    assert_not_predicate replacement_result, :reserved?
    assert_equal "email_connection_replaced", replacement_result.reason
  end

  test "does not reserve a reminder for a settled invoice" do
    @invoice.update!(status: :paid, paid_on: Date.current, amount_due: 0)

    result = reserve

    assert_not_predicate result, :reserved?
    assert_equal "not_outstanding", result.reason
    assert_nil result.message
  end

  test "does not reserve without a valid customer recipient" do
    @invoice.customer.update!(email: nil)

    result = reserve

    assert_not_predicate result, :reserved?
    assert_equal "missing_email", result.reason
  end

  test "reuses only the pending delivery owned by the same job" do
    first_result = reserve

    retry_result = reserve
    other_job_result = reserve(delivery_job_id: "another-job")

    assert_predicate retry_result, :reserved?
    assert_equal first_result.message, retry_result.message
    assert_equal first_result.message.internet_message_id, retry_result.message.internet_message_id
    assert_not_predicate other_job_result, :reserved?
    assert_equal "outbound_delivery_in_progress", other_job_result.reason
  end

  test "a deliberate one-off is allowed after recent contact" do
    @invoice.conversation_messages.create!(
      account: @account,
      conversation: Conversation.for_invoice!(invoice: @invoice),
      direction: :outbound,
      kind: :invoice_resend,
      status: :sent,
      sent_at: 1.minute.ago,
      provider_message_id: "recent-before-operator-reminder",
      from_address: "billing@paymentreminder.example",
      to_addresses: [ "customer@example.com" ],
      cc_addresses: [],
      subject: "Invoice INV-001",
      body: "Here is the invoice."
    )

    result = reserve

    assert_predicate result, :reserved?
    assert_predicate result.message, :kind_manual_reminder?
  end

  test "same-job sent history is an idempotent no-op" do
    first = reserve
    first.message.claim_provider_delivery!(job_id: "manual-reminder-job")
    first.message.mark_delivery_sent!(
      job_id: "manual-reminder-job",
      provider_message_id: "same-job-sent"
    )

    assert_no_difference -> { @invoice.conversation_messages.count } do
      replay = reserve

      assert_not_predicate replay, :reserved?
      assert_equal "already_sent", replay.reason
    end
  end

  test "same-job uncertain history is never reserved again" do
    first = reserve
    first.message.claim_provider_delivery!(job_id: "manual-reminder-job")
    first.message.mark_delivery_failed!(
      job_id: "manual-reminder-job",
      failure_reason: "Provider response was lost.",
      delivery_uncertain: true
    )

    assert_no_difference -> { @invoice.conversation_messages.count } do
      replay = reserve

      assert_not_predicate replay, :reserved?
      assert_equal "delivery_unconfirmed", replay.reason
    end
  end

  test "same-job definite failure is terminal but a new job may override cooldown" do
    first = reserve
    first.message.mark_delivery_failed!(
      job_id: "manual-reminder-job",
      failure_reason: "Recipient rejected."
    )

    assert_no_difference -> { @invoice.conversation_messages.count } do
      replay = reserve

      assert_not_predicate replay, :reserved?
      assert_equal "delivery_failed", replay.reason
    end
    new_request = reserve(delivery_job_id: "new-manual-reminder-job")
    assert_predicate new_request, :reserved?
    refute_equal first.message, new_request.message
  end

  test "the database rejects duplicate manual reminder job ownership" do
    reservation = reserve(
      delivery_job_id: "database-unique-manual-reminder"
    )
    duplicate = reservation.message.dup

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  private
    def reserve(delivery_job_id: "manual-reminder-job")
      InvoiceReminders::ManualDeliveryReservation.call(
        invoice: @invoice,
        delivery_job_id:
      )
    end
end

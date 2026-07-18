require "test_helper"

class OutboundEmailConnection::Gmail::DeliveryTest < ActiveSupport::TestCase
  test "sends the rendered multipart reminder through Gmail with the account sender" do
    invoice = invoices(:xero_invoice)
    invoice.provider_data["online_invoice_url"] = "https://example.com/invoices/INV-001"
    connection = outbound_email_connections(:paid_jar_gmail)
    invoice.account.update!(invoice_reminder_from_name: "Accounts Team")
    service = mock
    response = Struct.new(:id).new("gmail-message-123")
    captured_message = nil
    service.expects(:authorization=).with("gmail-access-token")
    service.expects(:send_user_message).with do |user_id, message|
      captured_message = Mail.read_from_string(message.raw)
      user_id == "me"
    end.returns(response)
    mail_message = InvoiceReminderMailer.reminder(
      invoice,
      invoice_schedules(:normal_pre_due_7)
    ).message

    message_id = OutboundEmailConnection::Gmail::Delivery.new(
      account: invoice.account,
      connection:,
      service:
    ).deliver(mail_message)

    assert_equal "gmail-message-123", message_id
    assert_equal [ "billing@paymentreminder.example" ], captured_message.from
    assert_equal [ "Accounts Team" ], captured_message[:from].display_names
    assert_equal [ "customer@example.com" ], captured_message.to
    assert_equal "Upcoming Payment Due: Invoice INV-001", captured_message.subject
    assert_match "friendly reminder", captured_message.text_part.body.to_s
    assert_match "https://example.com/invoices/INV-001", captured_message.text_part.body.to_s
    assert_match "https://example.com/invoices/INV-001", captured_message.html_part.body.to_s
  end

  test "refuses to deliver through another account's Gmail connection" do
    other_account = Account.create!(name: "Other Delivery Account")
    mail_message = InvoiceReminderMailer.reminder(
      invoices(:xero_invoice),
      invoice_schedules(:normal_pre_due_7)
    ).message

    error = assert_raises OutboundEmailConnection::Errors::PermanentDeliveryError do
      OutboundEmailConnection::Gmail::Delivery.new(
        account: other_account,
        connection: outbound_email_connections(:paid_jar_gmail),
        service: mock
      ).deliver(mail_message)
    end

    assert_match "not active for this account", error.message
  end

  test "marks the connection errored when Gmail revokes authorization" do
    connection = outbound_email_connections(:paid_jar_gmail)
    service = mock
    service.stubs(:authorization=)
    service.stubs(:send_user_message).raises(Google::Apis::AuthorizationError.new("revoked"))

    assert_raises OutboundEmailConnection::Errors::AuthenticationError do
      OutboundEmailConnection::Gmail::Delivery.new(
        account: connection.account,
        connection:,
        service:
      ).deliver(Mail.new(to: "customer@example.com", subject: "Test", body: "Test"))
    end

    assert_predicate connection.reload, :errored?
    assert_equal "revoked", connection.last_error
  end

  test "classifies Gmail rate limits as temporary" do
    connection = outbound_email_connections(:paid_jar_gmail)
    service = mock
    service.stubs(:authorization=)
    service.stubs(:send_user_message).raises(gmail_client_error("userRateLimitExceeded"))

    assert_raises OutboundEmailConnection::Errors::TemporaryDeliveryError do
      OutboundEmailConnection::Gmail::Delivery.new(
        account: connection.account,
        connection:,
        service:
      ).deliver(Mail.new(to: "customer@example.com", subject: "Test", body: "Test"))
    end

    assert_predicate connection.reload, :active?
  end

  private
    def gmail_client_error(reason)
      Google::Apis::ClientError.new(
        "Gmail rejected the request",
        status_code: 403,
        body: { error: { errors: [ { reason: } ] } }.to_json
      )
    end
end

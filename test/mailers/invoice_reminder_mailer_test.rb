require "test_helper"

class InvoiceReminderMailerTest < ActionMailer::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @account = @invoice.account
    @customer = @invoice.customer

    @account.update!(invoice_reminder_from_name: "Accounts Team")
    @customer.additional_email_addresses.create!(email: "bookkeeper@example.com")
  end

  test "sends one multipart pre-due reminder to every customer address from the account" do
    mail = InvoiceReminderMailer.reminder(@invoice, invoice_schedules(:normal_pre_due_7))

    assert_emails 1 do
      mail.deliver_now
    end

    assert_equal [ "customer@example.com", "bookkeeper@example.com" ], mail.to
    assert_equal [ "billing@paymentreminder.example" ], mail.from
    assert_equal [ "Accounts Team" ], mail[:from].display_names
    assert_equal "Upcoming Payment Due: Invoice INV-001", mail.subject
    assert_equal "text/plain", mail.text_part.mime_type
    assert_equal "text/html", mail.html_part.mime_type

    assert_match "friendly reminder", mail.text_part.body.to_s
    assert_match "due in 7 days", mail.text_part.body.to_s
    assert_invoice_details(mail.text_part.body.to_s)
    assert_invoice_details(Nokogiri::HTML(mail.html_part.body.to_s).text)
  end

  test "uses direct overdue copy" do
    mail = InvoiceReminderMailer.reminder(@invoice, invoice_schedules(:normal_overdue_3))

    assert_equal "Payment Reminder: Invoice INV-001", mail.subject
    assert_match "3 days overdue", mail.text_part.body.to_s
    assert_match "Please arrange payment", mail.text_part.body.to_s
  end

  test "uses urgent subject and final overdue copy for a final stage" do
    mail = InvoiceReminderMailer.reminder(@invoice, invoice_schedules(:normal_overdue_14))

    assert_equal "URGENT: Invoice INV-001 - Immediate Action Required", mail.subject
    assert_match "final reminder", mail.text_part.body.to_s
    assert_match "14 days overdue", mail.text_part.body.to_s
  end

  test "uses a due-soon heading for a firm pre-due stage" do
    stage = invoice_schedules(:normal_pre_due_7).dup
    stage.tone = :firm

    mail = InvoiceReminderMailer.reminder(@invoice, stage)

    assert_match "Payment is due soon", mail.text_part.body.to_s
    assert_no_match "Payment is overdue", mail.text_part.body.to_s
  end

  test "uses a pre-due heading for a final pre-due stage" do
    stage = invoice_schedules(:normal_pre_due_7).dup
    stage.tone = :final

    mail = InvoiceReminderMailer.reminder(@invoice, stage)

    assert_match "Final notice before payment is due", mail.text_part.body.to_s
    assert_no_match "Final payment reminder", mail.text_part.body.to_s
  end

  test "includes the provider's online invoice link in both parts" do
    @invoice.stubs(:online_invoice_url).returns("https://example.com/invoices/123")

    mail = InvoiceReminderMailer.reminder(@invoice, invoice_schedules(:normal_overdue_3))

    assert_match "View Invoice", mail.text_part.body.to_s
    assert_match "https://example.com/invoices/123", mail.text_part.body.to_s
    assert_match "View Invoice", mail.html_part.body.to_s
    assert_match "https://example.com/invoices/123", mail.html_part.body.to_s
  end

  test "omits the invoice call to action when no online invoice URL is available" do
    mail = InvoiceReminderMailer.reminder(@invoice, invoice_schedules(:normal_overdue_3))

    assert_no_match "View Invoice", mail.text_part.body.to_s
    assert_no_match "View Invoice", mail.html_part.body.to_s
  end

  private
    def assert_invoice_details(body)
      assert_match "Invoice: INV-001", body
      assert_match "Invoice date: July 01, 2026", body
      assert_match "Due date: July 31, 2026", body
      assert_match "Amount due: USD 125", body
    end
end

require "test_helper"

class InvoiceReminderNotificationMailerTest < ActionMailer::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @user = users(:arjun)
    @identity = Identity.create!(email_address: "invoice-notifications-#{SecureRandom.uuid}@example.com")
    @user.update!(identity: @identity)
  end

  test "pre-due reminder notification summarizes the customer delivery" do
    reminder = create_reminder(category: :pre_due, day_offset: 7, tone: :friendly)

    mail = InvoiceReminderNotificationMailer.reminder_sent(@user, @invoice, reminder)

    assert_equal [ @identity.email_address ], mail.to
    assert_equal "Upcoming Payment Due: Invoice INV-001", mail.subject
    assert_match "An automatic invoice reminder was sent to Example Customer", mail.text_part.body.to_s
    assert_match "Invoice: INV-001", mail.text_part.body.to_s
    assert_match "Due date: July 31, 2026", mail.text_part.body.to_s
    assert_match "Outstanding amount: USD 125", mail.text_part.body.to_s
    assert_match "Stage: Pre-due — 7 days before due", mail.text_part.body.to_s
    assert_match "Example Customer", mail.html_part.body.to_s
  end

  test "first overdue reminder uses the payment reminder subject" do
    reminder = create_reminder(category: :overdue, day_offset: 1, tone: :neutral)

    mail = InvoiceReminderNotificationMailer.reminder_sent(@user, @invoice, reminder)

    assert_equal "Payment Reminder: Invoice INV-001", mail.subject
    assert_match "Stage: Overdue — 1 day overdue", mail.text_part.body.to_s
  end

  test "later overdue reminder uses the payment overdue subject" do
    reminder = create_reminder(category: :overdue, day_offset: 7, tone: :firm)

    mail = InvoiceReminderNotificationMailer.reminder_sent(@user, @invoice, reminder)

    assert_equal "Payment Overdue: Invoice INV-001", mail.subject
    assert_match "Stage: Overdue — 7 days overdue", mail.text_part.body.to_s
  end

  test "terminal reminder uses the urgent subject independently of tone" do
    reminder = create_reminder(category: :overdue, day_offset: 14, tone: :firm)

    mail = InvoiceReminderNotificationMailer.reminder_sent(
      @user,
      @invoice,
      reminder,
      terminal: true
    )

    assert_equal "URGENT: Invoice INV-001 - Immediate Action Required", mail.subject
  end

  test "manual follow-up notification explains that the reminder cycle is complete" do
    reminder = create_reminder(category: :overdue, day_offset: 14, tone: :final)

    mail = InvoiceReminderNotificationMailer.manual_follow_up(@user, @invoice, reminder)

    assert_equal [ @identity.email_address ], mail.to
    assert_equal "Final Reminder Sent for Invoice INV-001 - Manual Follow-up Required", mail.subject
    assert_match "The automated reminder cycle for invoice INV-001 is complete", mail.text_part.body.to_s
    assert_match "Client: Example Customer", mail.text_part.body.to_s
    assert_match "Due date: July 31, 2026", mail.text_part.body.to_s
    assert_match "Days overdue: 14", mail.text_part.body.to_s
    assert_match "Outstanding amount: USD 125", mail.text_part.body.to_s
    assert_match "Contact the client directly", mail.text_part.body.to_s
    assert_match "Manual follow-up", mail.html_part.body.to_s
  end

  test "notification subjects fall back to the provider invoice id" do
    @invoice.update!(number: nil)
    reminder = create_reminder(category: :pre_due, day_offset: 7, tone: :friendly)

    mail = InvoiceReminderNotificationMailer.reminder_sent(@user, @invoice, reminder)

    assert_equal "Upcoming Payment Due: Invoice invoice-123", mail.subject
    assert_match "Invoice: invoice-123", mail.text_part.body.to_s
  end

  private
    def create_reminder(category:, day_offset:, tone:)
      @invoice.invoice_reminders.create!(
        account: @invoice.account,
        category:,
        day_offset:,
        stage_key: "#{category}_#{day_offset}",
        status: :sent,
        sent_at: Time.current,
        tone:
      )
    end
end

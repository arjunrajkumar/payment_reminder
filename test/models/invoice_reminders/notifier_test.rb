require "test_helper"

class InvoiceReminders::NotifierTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @invoice = invoices(:xero_invoice)
    @reminder = @invoice.invoice_reminders.create!(
      account: @invoice.account,
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      status: :sent,
      sent_at: Time.current,
      tone: :friendly
    )
  end

  test "emails only active subscribed users in the invoice account" do
    subscribed_user = create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "subscribed@example.com"
    )
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "inactive@example.com",
      active: false
    )
    create_subscriber(
      account: Account.create!(name: "Other Notification Account"),
      event: :invoice_reminder,
      email: "other-account@example.com"
    )
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "disabled@example.com",
      enabled: false
    )

    assert_emails 1 do
      InvoiceReminders::Notifier.deliver(invoice: @invoice, reminder: @reminder, terminal: false)
    end

    assert_equal [ subscribed_user.identity.email_address ], ActionMailer::Base.deliveries.last.to
  end

  test "terminal delivery sends the independently subscribed manual follow-up event" do
    create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder_stopped,
      email: "follow-up@example.com"
    )

    assert_emails 1 do
      InvoiceReminders::Notifier.deliver(invoice: @invoice, reminder: @reminder, terminal: true)
    end

    assert_equal "Final Reminder Sent for Invoice INV-001 - Manual Follow-up Required",
      ActionMailer::Base.deliveries.last.subject
  end

  test "one event failure does not prevent the terminal follow-up event" do
    user = create_subscriber(
      account: @invoice.account,
      event: :invoice_reminder,
      email: "both-events@example.com"
    )
    user.notification_subscriptions.create!(event: :invoice_reminder_stopped, email: true)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).raises(StandardError, "delivery failed")
    Rails.logger.stubs(:error)

    assert_emails 1 do
      InvoiceReminders::Notifier.deliver(invoice: @invoice, reminder: @reminder, terminal: true)
    end

    assert_equal "Final Reminder Sent for Invoice INV-001 - Manual Follow-up Required",
      ActionMailer::Base.deliveries.last.subject
  end

  private
    def create_subscriber(account:, event:, email:, active: true, enabled: true)
      identity = Identity.create!(email_address: email)
      account.users.create!(
        name: email,
        identity:,
        active:
      ).tap do |user|
        user.notification_subscriptions.create!(event:, email: enabled)
      end
    end
end

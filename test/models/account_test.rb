require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "automatic invoice reminders are disabled by default" do
    account = Account.create!(name: "Disabled Reminder Account")

    assert_not_predicate account, :automatic_invoice_reminders_enabled?
  end

  test "requires a sender email when automatic invoice reminders are enabled" do
    account = Account.new(
      name: "Missing Sender Account",
      automatic_invoice_reminders_enabled: true
    )

    assert_not account.valid?
    assert_includes account.errors[:invoice_reminder_from_email], "can't be blank"
  end

  test "normalizes the invoice reminder sender email" do
    account = Account.create!(
      name: "Normalized Sender Account",
      invoice_reminder_from_email: " Billing@Example.COM "
    )

    assert_equal "billing@example.com", account.invoice_reminder_from_email
  end

  test "rejects an invalid invoice reminder sender email" do
    account = Account.new(
      name: "Invalid Sender Account",
      invoice_reminder_from_email: "not-an-email"
    )

    assert_not account.valid?
    assert_includes account.errors[:invoice_reminder_from_email], "is invalid"
  end

  test "rejects an invoice reminder sender longer than a mailbox address" do
    account = Account.new(
      name: "Long Sender Account",
      invoice_reminder_from_email: "#{"a" * 243}@example.com"
    )

    assert_not account.valid?
    assert_includes account.errors[:invoice_reminder_from_email], "is too long (maximum is 254 characters)"
  end

  test "has many users" do
    assert_includes accounts(:paid_jar).users, users(:arjun)
  end

  test "has many invoice sources" do
    assert_includes accounts(:paid_jar).invoice_sources, invoice_sources(:xero)
  end

  test "has many invoices" do
    assert_includes accounts(:paid_jar).invoices, invoices(:xero_invoice)
  end

  test "has many customers" do
    assert_includes accounts(:paid_jar).customers, customers(:xero_customer)
  end

  test "has many invoice schedules" do
    assert_includes accounts(:paid_jar).invoice_schedules, invoice_schedules(:good_pre_due_3)
  end

  test "has one rule for every customer payer segment" do
    account = accounts(:paid_jar)

    assert_equal CustomerSegment::PAYER_SEGMENTS.keys.sort, account.customer_segments.pluck(:payer_segment).sort
  end

  test "creates account with owner and system user" do
    identity = Identity.create!(email_address: "owner@example.com")
    account = Account.create_with_owner(
      account: { name: "Owner Account" },
      owner: { name: "Owner User", identity: identity }
    )

    assert_predicate account.users.find_by!(role: :system), :system?
    assert_predicate account.users.find_by!(identity: identity), :owner?
    assert_nil account.invoice_reminder_from_email
  end

  test "keeps an explicit invoice reminder sender when creating an account with an owner" do
    identity = Identity.create!(email_address: "owner-explicit@example.com")
    account = Account.create_with_owner(
      account: {
        name: "Explicit Sender Account",
        invoice_reminder_from_email: "accounts@example.com"
      },
      owner: { name: "Owner User", identity: identity }
    )

    assert_equal "accounts@example.com", account.invoice_reminder_from_email
  end

  test "rolls back account when owner creation fails" do
    identity = Identity.create!(email_address: "invalid-owner@example.com")

    assert_no_difference [ -> { Account.count }, -> { CustomerSegment.count }, -> { User.count } ] do
      assert_raises ActiveRecord::RecordInvalid do
        Account.create_with_owner(
          account: { name: "Invalid Owner Account" },
          owner: { name: "", identity: identity }
        )
      end
    end
  end

  test "slug" do
    assert_equal "/#{accounts(:paid_jar).external_account_id}", accounts(:paid_jar).slug
  end

  test "external account id auto-increments on creation" do
    account1 = Account.create!(name: "First Account")
    account2 = Account.create!(name: "Second Account")

    assert_not_nil account1.external_account_id
    assert_not_nil account2.external_account_id
    assert_equal account1.external_account_id + 1, account2.external_account_id
  end

  test "external account id can be overridden" do
    custom_id = 999999
    sequence = Account::ExternalIdSequence.first_or_create!(value: 0)
    sequence_value_before = sequence.value

    account = Account.create!(name: "Custom ID Account", external_account_id: custom_id)

    assert_equal custom_id, account.external_account_id
    assert_equal sequence_value_before, sequence.reload.value
  end

  test "requires an external account id after creation" do
    account = Account.create!(name: "Account Missing External ID")
    account.external_account_id = nil

    assert_not account.valid?
    assert_includes account.errors[:external_account_id], "can't be blank"
  end

  test "requires a name" do
    account = Account.new

    assert_not account.valid?
    assert_includes account.errors[:name], "can't be blank"
  end

  test "creates the current debtor rating rule defaults" do
    account = Account.create!(name: "Segment Defaults")

    assert_equal 3, account.customer_segments.size
    assert_equal 80, account.customer_segment(:good_debtor).on_time_rate
    assert_nil account.customer_segment(:normal_debtor).on_time_rate
    assert_equal 50, account.customer_segment(:bad_debtor).on_time_rate
  end

  test "creates the default invoice schedules" do
    account = Account.create!(name: "Invoice Schedule Defaults")
    expected_schedules = InvoiceReminders::Policy::SCHEDULES.flat_map do |kind, stages|
      stages.map do |stage|
        [ kind.to_s, stage.category.to_s, stage.day_offset, stage.tone.to_s ]
      end
    end
    actual_schedules = account.invoice_schedules.map do |schedule|
      [ schedule.kind, schedule.category, schedule.day_offset, schedule.tone ]
    end

    assert_equal expected_schedules.sort, actual_schedules.sort
  end

  test "keeps the good debtor threshold above the bad debtor threshold" do
    account = Account.create!(name: "Overlapping Segment Rules")
    account.assign_attributes(
      customer_segments_attributes: [
        { id: account.customer_segment(:good_debtor).id, on_time_rate: 50 },
        { id: account.customer_segment(:bad_debtor).id, on_time_rate: 50 }
      ]
    )

    assert_not account.valid?
    assert_includes account.errors[:base], "Good Debtor on-time rate must stay above the Bad Debtor on-time rate"
  end

  test "destroys an account with a complete conversation audit lifecycle" do
    account = accounts(:paid_jar)
    invoice = invoices(:xero_invoice)
    conversation = Conversation.for_invoice!(invoice:)
    reminder_message = invoice.conversation_messages.create!(
      account:,
      conversation:,
      direction: :outbound,
      kind: :scheduled_reminder,
      status: :sent,
      sent_at: Time.current,
      to_addresses: [],
      cc_addresses: []
    )
    reminder = invoice.invoice_reminders.create!(
      account:,
      conversation_message: reminder_message,
      category: :pre_due,
      stage_key: "pre_due_7",
      day_offset: 7
    )
    recipient = account.users.create!(
      name: "Notification lifecycle",
      identity: Identity.create!(
        email_address: "notification-lifecycle@example.com"
      ),
      verified_at: Time.current
    )
    notification = reminder.notification_deliveries.create!(
      account:,
      recipient_user: recipient,
      recipient_user_snapshot_id: recipient.id,
      recipient_email: recipient.identity.email_address,
      event_name: InvoiceReminders::Notifier::EVENTS.fetch(:reminder)
    )
    source_message = invoice.conversation_messages.create!(
      account:,
      conversation:,
      direction: :inbound,
      kind: :customer_reply,
      status: :received,
      received_at: Time.current,
      to_addresses: [],
      cc_addresses: []
    )
    payment_promise = PaymentPromise.record!(
      invoice:,
      source_message:,
      promised_on: Date.current + 1.day
    )
    conversation.resolve!
    event_ids = conversation.conversation_events.ids

    assert_nothing_raised { account.destroy! }
    assert_not Conversation.exists?(conversation.id)
    assert_not ConversationEvent.where(id: event_ids).exists?
    assert_not ConversationMessage.where(id: [ reminder_message.id, source_message.id ]).exists?
    assert_not InvoiceReminder.exists?(reminder.id)
    assert_not InvoiceReminderNotificationDelivery.exists?(notification.id)
    assert_not PaymentPromise.exists?(payment_promise.id)
  end

  test "refreshes every customer payer segment" do
    account = Account.create!(name: "Segment Refresh Account")
    source = account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "segment-refresh-source"
    )
    source.customers.create!(
      account: account,
      external_id: "segment-refresh-customer",
      name: "Segment Refresh Customer"
    )

    Customer.any_instance.expects(:refresh_customer_segment!).once

    assert_same account, account.refresh_customer_segments!
  end
end

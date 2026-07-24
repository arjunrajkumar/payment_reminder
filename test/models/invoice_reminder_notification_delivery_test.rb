require "test_helper"

class InvoiceReminderNotificationDeliveryTest < ActiveSupport::TestCase
  setup do
    invoice = invoices(:xero_invoice)
    message = invoice.conversation_messages.create!(
      account: invoice.account,
      conversation: Conversation.for_invoice!(invoice:),
      direction: :outbound,
      kind: :scheduled_reminder,
      status: :sent,
      sent_at: Time.current
    )
    reminder = invoice.invoice_reminders.create!(
      account: invoice.account,
      conversation_message: message,
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      tone: :friendly
    )
    user = invoice.account.users.create!(
      name: "Notification lease",
      identity: Identity.create!(email_address: "notification-lease@example.com"),
      verified_at: Time.current
    )
    @outcome = reminder.notification_deliveries.create!(
      account: invoice.account,
      recipient_user: user,
      recipient_user_snapshot_id: user.id,
      recipient_email: user.identity.email_address,
      event_name: "invoice_reminder"
    )
  end

  test "an active claim can only be completed by its attempt token" do
    assert @outcome.claim_for_delivery!(attempt_token: "owner", at: Time.current)
    assert_not @outcome.claim_for_delivery!(attempt_token: "contender", at: Time.current)
    assert_not @outcome.record_delivered!(attempt_token: "contender")
    assert_predicate @outcome.reload, :status_delivering?

    assert @outcome.record_delivered!(attempt_token: "owner")
    assert_predicate @outcome.reload, :status_delivered?
  end

  test "only the recurring repair path adjudicates an explicitly stale claim" do
    @outcome.claim_for_delivery!(
      attempt_token: "abandoned",
      at: InvoiceReminderNotificationDelivery::STALE_AFTER.ago - 1.second
    )

    assert @outcome.adjudicate_stale_claim!(
      before: InvoiceReminderNotificationDelivery::STALE_AFTER.ago
    )
    assert_predicate @outcome.reload, :status_uncertain?
    assert_not @outcome.claim_for_delivery!(attempt_token: "replacement")
  end

  test "build ownership is exclusive and only its token can record failure" do
    assert_equal :claimed, @outcome.claim_for_build!(
      build_token: "builder",
      at: Time.current
    )
    assert_equal :busy, @outcome.claim_for_build!(
      build_token: "contender",
      at: Time.current
    )
    assert_not @outcome.record_build_failure!(
      build_token: "contender",
      error: StandardError.new("not owner"),
      retry_at: 1.minute.from_now
    )
    assert_equal 0, @outcome.reload.build_attempts

    assert_equal :pending, @outcome.record_build_failure!(
      build_token: "builder",
      error: StandardError.new("render failed"),
      retry_at: 1.minute.from_now
    )
    assert_equal 1, @outcome.reload.build_attempts
    assert_nil @outcome.build_token
    assert_nil @outcome.build_started_at
  end

  test "a stale build is definitely unsent and can be reclaimed" do
    stale_at = InvoiceReminderNotificationDelivery::BUILD_STALE_AFTER.ago -
      1.second
    assert_equal :claimed, @outcome.claim_for_build!(
      build_token: "abandoned",
      at: stale_at
    )

    assert @outcome.release_stale_build!(
      before: InvoiceReminderNotificationDelivery::BUILD_STALE_AFTER.ago
    )
    assert_equal 0, @outcome.reload.build_attempts
    assert_equal :claimed, @outcome.claim_for_build!(
      build_token: "replacement",
      at: Time.current
    )
  end
end

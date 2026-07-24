require "test_helper"

class InvoiceReminders::SendJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @invoice = invoices(:xero_invoice)
    @invoice.account.update!(automatic_invoice_reminders_enabled: true)
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(@invoice)
    @delivery_result = EmailConnection::Delivery::Result.new(
      provider_message_id: "gmail-message-123",
      provider_thread_id: "gmail-thread-456"
    )
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver).returns(@delivery_result)
  end

  test "limits concurrency to one job for each invoice" do
    first_job = InvoiceReminders::SendJob.new(@invoice.id, "pre_due", 7, "friendly")
    same_stage_job = InvoiceReminders::SendJob.new(@invoice.id, "pre_due", 7, "final")
    other_invoice_job = InvoiceReminders::SendJob.new(@invoice.id + 1, "pre_due", 7, "friendly")
    other_stage_job = InvoiceReminders::SendJob.new(@invoice.id, "overdue", 3, "direct")

    assert_predicate first_job, :concurrency_limited?
    assert_equal "InvoiceReminders::SendJob/#{@invoice.id}", first_job.concurrency_key
    assert_equal first_job.concurrency_key, same_stage_job.concurrency_key
    refute_equal first_job.concurrency_key, other_invoice_job.concurrency_key
    assert_equal first_job.concurrency_key, other_stage_job.concurrency_key
    assert_equal 1, InvoiceReminders::SendJob.concurrency_limit
    assert_equal 1.hour, InvoiceReminders::SendJob.concurrency_duration
    assert_equal :block, InvoiceReminders::SendJob.concurrency_on_conflict
  end

  test "a duplicate job released after delivery does not send again" do
    InvoiceReminders::SendJob.any_instance.expects(:send_email).once.returns(@delivery_result)

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_enqueued_jobs 2, only: InvoiceReminders::SendJob do
        2.times do
          InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
        end
      end

      assert_difference -> { @invoice.invoice_reminders.count }, 1 do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end
    end
  end

  test "a sent-job replay repairs missing notifications without resending the reminder" do
    subscribe_to(:invoice_reminder)
    reminder = create_reminder(
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      status: :sent,
      sent_at: Time.current
    )
    reminder.update!(terminal_at_delivery: false)
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    assert_emails 1 do
      InvoiceReminders::SendJob.perform_now(
        @invoice.id,
        "pre_due",
        7,
        "friendly"
      )
    end
    assert_predicate reminder.notification_deliveries.sole,
      :status_delivered?

    assert_no_emails do
      InvoiceReminders::SendJob.perform_now(
        @invoice.id,
        "pre_due",
        7,
        "friendly"
      )
    end
  end

  test "creates a sent receipt after sending the email" do
    sent_at = Time.zone.local(2026, 7, 24, 12)

    travel_to sent_at do
      assert_no_emails do
        assert_difference [
          -> { @invoice.invoice_reminders.count },
          -> { @invoice.conversation_messages.count }
        ], 1 do
          InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
        end
      end
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7")
    assert_equal @invoice.account, reminder.account
    assert_predicate reminder, :category_pre_due?
    assert_equal 7, reminder.day_offset
    assert_predicate reminder, :status_sent?
    assert_equal sent_at, reminder.sent_at
    assert_equal "gmail-message-123", reminder.provider_message_id
    assert_equal "gmail-thread-456", reminder.provider_thread_id
    assert_nil reminder.failure_reason

    message = reminder.conversation_message
    assert_predicate message, :direction_outbound?
    assert_predicate message, :kind_scheduled_reminder?
    assert_equal [ "billing@paymentreminder.example" ], [ message.from_address ]
    assert_equal [ "customer@example.com" ], message.to_addresses
    assert_equal [], message.cc_addresses
    assert_equal "Upcoming Payment Due: Invoice INV-001", message.subject
    assert_match "friendly reminder", message.body
  end

  test "creates a failed receipt when the email is not sent" do
    subscribe_to(:invoice_reminder)
    InvoiceReminders::SendJob.any_instance.stubs(:send_email).returns(false)

    travel_to Time.zone.local(2026, 8, 3, 12) do
      assert_no_emails do
        assert_difference -> { @invoice.invoice_reminders.count }, 1 do
          InvoiceReminders::SendJob.perform_now(@invoice.id, "overdue", 3, "direct")
        end
      end
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "overdue_3")
    assert_predicate reminder, :status_failed?
    assert_nil reminder.sent_at
  end

  test "does not mark delivery sent without a provider message ID" do
    unconfirmed_result = EmailConnection::Delivery::Result.new(
      provider_message_id: nil,
      provider_thread_id: "gmail-thread-without-message"
    )
    InvoiceReminders::SendJob.any_instance.stubs(:send_email).returns(unconfirmed_result)

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end

    message = @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7").conversation_message
    assert_predicate message, :status_failed?
    assert_equal "Email provider did not confirm delivery.", message.failure_reason
    assert_nil message.provider_thread_id
  end

  test "records the failure reason when sending raises an error" do
    InvoiceReminders::SendJob.any_instance
      .stubs(:send_email)
      .raises(StandardError, "delivery failed")

    travel_to Time.zone.local(2026, 8, 3, 12) do
      assert_difference -> { @invoice.invoice_reminders.count }, 1 do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "overdue", 3, "direct")
      end
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "overdue_3")
    assert_predicate reminder, :status_failed?
    assert_equal "delivery failed", reminder.failure_reason
    assert_nil reminder.sent_at
  end

  test "notifies subscribed users after a successful reminder" do
    subscribe_to(:invoice_reminder)

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_emails 1 do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
      end
    end

    assert_equal "Upcoming Payment Due: Invoice INV-001", ActionMailer::Base.deliveries.last.subject
  end

  test "sends the reminder and manual follow-up notifications after the terminal stage" do
    subscribe_to(:invoice_reminder, :invoice_reminder_stopped)

    travel_to Time.zone.local(2026, 8, 14, 12) do
      assert_emails 2 do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "overdue", 14, "final")
      end
    end

    assert_equal [
      "URGENT: Invoice INV-001 - Immediate Action Required",
      "Final Reminder Sent for Invoice INV-001 - Manual Follow-up Required"
    ], ActionMailer::Base.deliveries.last(2).map(&:subject)
  end

  test "a notification failure does not change a successful reminder receipt" do
    subscribe_to(:invoice_reminder)
    InvoiceReminderNotificationMailer.stubs(:reminder_sent).raises(StandardError, "notification failed")
    Rails.logger.stubs(:error)

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_difference -> { @invoice.invoice_reminders.count }, 1 do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
      end
    end

    assert_predicate @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7"), :status_sent?
  end

  test "does not send a queued reminder after the account disables reminders" do
    @invoice.account.update!(automatic_invoice_reminders_enabled: false)
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    assert_no_difference -> { @invoice.invoice_reminders.count } do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end
  end

  test "does not send or create a duplicate receipt" do
    create_reminder(
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      status: :failed
    )
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    assert_no_difference -> { @invoice.invoice_reminders.count } do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end
  end

  test "does not send a queued reminder after the invoice is paid" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_enqueued_with(
        job: InvoiceReminders::SendJob,
        args: [ @invoice.id, "pre_due", 7, "friendly" ]
      ) do
        InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      end

      @invoice.update!(status: :paid, amount_due: 0, paid_on: Date.current)
      InvoiceReminders::SendJob.any_instance.expects(:send_email).never

      assert_no_difference -> { @invoice.invoice_reminders.count } do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end
    end
  end

  test "refreshes a Xero invoice and does not send when the provider reports it paid" do
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).with do |invoice|
      @invoice.update!(status: :paid, amount_due: 0, paid_on: Date.current)
      invoice.invoice_source.xero?
    end.returns(@invoice)
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_difference -> { @invoice.invoice_reminders.count } do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
      end
    end
  end

  test "the locked reservation catches reminders disabled during invoice refresh" do
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).with do |invoice|
      @invoice.account.update!(automatic_invoice_reminders_enabled: false)
      invoice == @invoice
    end.returns(@invoice)
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_difference -> { @invoice.invoice_reminders.count } do
        assert_no_difference -> { @invoice.conversation_messages.count } do
          InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
        end
      end
    end
  end

  test "refreshes a Stripe invoice and does not send when the provider reports it paid" do
    invoice = create_stripe_invoice
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).with do |refreshed_invoice|
      invoice.update!(status: :paid, amount_due: 0, paid_on: Date.current)
      refreshed_invoice.invoice_source.stripe?
    end.returns(invoice)
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_difference -> { invoice.invoice_reminders.count } do
        InvoiceReminders::SendJob.perform_now(invoice.id, "pre_due", 7, "friendly")
      end
    end
  end

  test "retries a Xero refresh failure without sending or recording a receipt" do
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call)
      .raises(InvoiceSources::Xero::OauthClient::Error, "Xero unavailable")
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_enqueued_jobs 1, only: InvoiceReminders::SendJob do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
      end
    end

    assert_not @invoice.invoice_reminders.exists?(stage_key: "pre_due_7")
  end

  test "retries a Stripe refresh failure without sending or recording a receipt" do
    invoice = create_stripe_invoice
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call)
      .raises(InvoiceSources::Stripe::ApiClient::Error, "Stripe unavailable")
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_enqueued_jobs 1, only: InvoiceReminders::SendJob do
        InvoiceReminders::SendJob.perform_now(invoice.id, "pre_due", 7, "friendly")
      end
    end

    assert_not invoice.invoice_reminders.exists?(stage_key: "pre_due_7")
  end

  test "does not send a queued reminder after the due date changes" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      @invoice.update!(due_on: @invoice.due_on + 1.day)
      InvoiceReminders::SendJob.any_instance.expects(:send_email).never

      assert_no_difference -> { @invoice.invoice_reminders.count } do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end
    end
  end

  test "does not permanently suppress a queued stage that is no longer due" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      @invoice.update!(due_on: @invoice.due_on + 1.day)
      create_message(kind: :invoice_resend, status: :sent, sent_at: Time.current)

      perform_enqueued_jobs(only: InvoiceReminders::SendJob)
    end

    assert_not @invoice.invoice_reminder_suppressions.exists?(stage_key: "pre_due_7")
  end

  test "does not send a queued stage absent from the customer's current policy" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      @invoice.customer.update!(customer_segment: customer_segments(:good_debtor_segment))
      InvoiceReminders::SendJob.any_instance.expects(:send_email).never

      assert_no_difference -> { @invoice.invoice_reminders.count } do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end
    end
  end

  test "uses the current policy tone when the customer's rating changes" do
    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      @invoice.customer.update!(customer_segment: customer_segments(:bad_debtor_segment))
      InvoiceReminders::SendJob.any_instance.expects(:send_email).once.returns(@delivery_result)

      assert_difference -> { @invoice.invoice_reminders.count }, 1 do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end

      assert_predicate @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7"),
        :tone_direct?
    end
  end

  test "uses the current persisted schedule tone instead of the queued tone" do
    schedule = replace_schedule(
      kind: @invoice.customer.payer_segment,
      category: "pre_due",
      day_offset: 7,
      tone: "friendly"
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      schedule.update!(tone: "firm")
      InvoiceReminders::SendJob.any_instance.expects(:send_email).once.returns(@delivery_result)

      assert_difference -> { @invoice.invoice_reminders.count }, 1 do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end
    end

    assert_predicate @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7"), :tone_firm?
  end

  test "skips a queued reminder after its persisted schedule is deleted" do
    schedule = replace_schedule(
      kind: @invoice.customer.payer_segment,
      category: "pre_due",
      day_offset: 7,
      tone: "friendly"
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      schedule.destroy!
      InvoiceReminders::SendJob.any_instance.expects(:send_email).never

      assert_no_difference -> { @invoice.invoice_reminders.count } do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end
    end
  end

  test "records the delivery when its schedule is deleted while sending" do
    schedule = replace_schedule(
      kind: @invoice.customer.payer_segment,
      category: "pre_due",
      day_offset: 7,
      tone: "friendly"
    )
    delivery_result = @delivery_result
    job = InvoiceReminders::SendJob.new(@invoice.id, "pre_due", 7, "friendly")
    job.define_singleton_method(:send_email) do |**|
      schedule.destroy!
      delivery_result
    end

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_difference -> { @invoice.invoice_reminders.count }, 1 do
        job.perform_now
      end
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7")
    assert_nil reminder.invoice_schedule
    assert_predicate reminder, :status_sent?
    assert_predicate reminder, :tone_friendly?
  end

  test "skips a queued reminder after its persisted schedule timing changes" do
    schedule = replace_schedule(
      kind: @invoice.customer.payer_segment,
      category: "pre_due",
      day_offset: 7,
      tone: "friendly"
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      schedule.update!(day_offset: 5)
      InvoiceReminders::SendJob.any_instance.expects(:send_email).never

      assert_no_difference -> { @invoice.invoice_reminders.count } do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end
    end
  end

  test "does not resend the same persisted schedule after its timing changes" do
    schedule = replace_schedule(
      kind: @invoice.customer.payer_segment,
      category: "pre_due",
      day_offset: 7,
      tone: "friendly"
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end

    assert_equal schedule, @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7").invoice_schedule

    schedule.update!(day_offset: 6)
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 25, 12) do
      assert_no_difference -> { @invoice.invoice_reminders.count } do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 6, "friendly")
      end
    end
  end

  test "records the current policy tone on a sent receipt" do
    @invoice.customer.update!(customer_segment: customer_segments(:bad_debtor_segment))

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7")
    assert_predicate reminder, :tone_direct?
  end

  test "records the current policy tone on a failed receipt" do
    InvoiceReminders::SendJob.any_instance.stubs(:send_email).returns(false)

    travel_to Time.zone.local(2026, 8, 3, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "overdue", 3, "direct")
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "overdue_3")
    assert_predicate reminder, :status_failed?
    assert_predicate reminder, :tone_direct?
  end

  test "does not trust a queued final tone" do
    subscribe_to(:invoice_reminder_stopped)
    InvoiceReminders::SendJob.any_instance.expects(:send_email).once.returns(@delivery_result)

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_emails do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "final")
      end
    end
  end

  test "the terminal stage still triggers manual follow-up when its tone changes" do
    subscribe_to(:invoice_reminder_stopped)
    @invoice.account.invoice_schedules.find_by!(
      kind: @invoice.customer.payer_segment,
      category: :overdue,
      day_offset: 14
    ).update!(tone: :firm)

    travel_to Time.zone.local(2026, 8, 14, 12) do
      assert_emails 1 do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "overdue", 14, "final")
      end
    end

    assert_equal "Final Reminder Sent for Invoice INV-001 - Manual Follow-up Required",
      ActionMailer::Base.deliveries.last.subject
  end

  test "a pre-due-only sequence does not trigger an overdue manual follow-up" do
    subscribe_to(:invoice_reminder_stopped)
    @invoice.account.invoice_schedules.where(
      kind: @invoice.customer.payer_segment,
      category: :overdue
    ).delete_all

    travel_to Time.zone.local(2026, 7, 30, 12) do
      assert_no_emails do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 1, "direct")
      end
    end

    assert_predicate @invoice.invoice_reminders.find_by!(stage_key: "pre_due_1"), :status_sent?
  end

  test "skips a customer without an email and creates no receipt" do
    @invoice.customer.update!(email: nil)
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never
    Rails.logger.expects(:warn).with(
      "invoice_reminder.skipped reason=missing_email " \
        "account_id=#{@invoice.account_id} invoice_id=#{@invoice.id} " \
        "customer_id=#{@invoice.customer_id} stage_key=pre_due_7"
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_difference -> { @invoice.invoice_reminders.count } do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
      end
    end
  end

  test "uses an additional customer email added after the reminder was queued" do
    @invoice.customer.update!(email: nil)
    delivered_message = nil
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver).with do |message|
      delivered_message = message
      true
    end.returns("gmail-message-456")

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      @invoice.customer.additional_email_addresses.create!(email: "accounts@example.com")

      assert_no_emails do
        assert_difference -> { @invoice.invoice_reminders.count }, 1 do
          perform_enqueued_jobs(only: InvoiceReminders::SendJob)
        end
      end
    end

    assert_equal [ "accounts@example.com" ], delivered_message.to
  end

  test "skips an account whose sender does not match its Gmail connection" do
    @invoice.account.update_column(:invoice_reminder_from_email, nil)
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never
    Rails.logger.expects(:warn).with(
      "invoice_reminder.skipped reason=sender_address_mismatch " \
        "account_id=#{@invoice.account_id} invoice_id=#{@invoice.id} stage_key=pre_due_7"
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_difference -> { @invoice.invoice_reminders.count } do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
      end
    end
  end

  test "logs a missing invoice" do
    Rails.logger.expects(:warn).with(
      "invoice_reminder.skipped reason=missing_invoice invoice_id=-1 stage_key=pre_due_7"
    )

    InvoiceReminders::SendJob.perform_now(-1, "pre_due", 7, "friendly")
  end

  test "logs a disabled account" do
    @invoice.account.update!(automatic_invoice_reminders_enabled: false)
    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(
      "invoice_reminder.skipped reason=disabled_account " \
        "account_id=#{@invoice.account_id} invoice_id=#{@invoice.id} stage_key=pre_due_7"
    )

    InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
  end

  test "logs a duplicate stage" do
    create_reminder(
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      status: :sent,
      sent_at: Time.current
    )
    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(
      "invoice_reminder.skipped reason=duplicate_stage " \
        "account_id=#{@invoice.account_id} invoice_id=#{@invoice.id} stage_key=pre_due_7"
    )

    InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
  end

  test "logs a successful delivery" do
    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with(
      "invoice_reminder.delivery_succeeded " \
        "account_id=#{@invoice.account_id} invoice_id=#{@invoice.id} stage_key=pre_due_7"
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end
  end

  test "logs a failed delivery" do
    InvoiceReminders::SendJob.any_instance.stubs(:send_email).returns(false)
    Rails.logger.expects(:error).with(
      "invoice_reminder.delivery_failed " \
        "account_id=#{@invoice.account_id} invoice_id=#{@invoice.id} stage_key=overdue_3"
    )

    travel_to Time.zone.local(2026, 8, 3, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "overdue", 3, "direct")
    end
  end

  test "uses the current Gmail connection belonging to the invoice account" do
    connection = email_connections(:paid_jar_gmail)
    delivery = mock
    delivery.expects(:deliver).returns("gmail-account-message")
    EmailConnection::Gmail::Delivery.expects(:new).with(
      account: @invoice.account,
      connection:,
      provider_account_id: connection.provider_account_id,
      credential_generation: connection.credential_generation
    ).returns(delivery)

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end

    assert_equal "gmail-account-message",
      @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7").provider_message_id
  end

  test "missing Gmail connection is skipped without a receipt" do
    @invoice.account.email_connection.destroy!
    Rails.logger.expects(:warn).with(
      "invoice_reminder.skipped reason=missing_email_connection " \
        "account_id=#{@invoice.account_id} invoice_id=#{@invoice.id} stage_key=pre_due_7"
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_difference -> { @invoice.invoice_reminders.count } do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
      end
    end
  end

  test "inactive Gmail connection is skipped without a receipt" do
    @invoice.account.email_connection.update!(status: :disconnected)
    Rails.logger.expects(:warn).with(
      "invoice_reminder.skipped reason=missing_email_connection " \
        "account_id=#{@invoice.account_id} invoice_id=#{@invoice.id} stage_key=pre_due_7"
    )

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_difference -> { @invoice.invoice_reminders.count } do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
      end
    end
  end

  test "revoked Gmail authorization records a failed receipt" do
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver)
      .raises(EmailConnection::Errors::AuthenticationError, "invalid_grant")

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7")
    assert_predicate reminder, :status_failed?
    assert_equal "invalid_grant", reminder.failure_reason
  end

  test "permanent Gmail failure records a failed receipt without retry" do
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver)
      .raises(EmailConnection::Errors::PermanentDeliveryError, "invalid recipient")

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_enqueued_jobs only: InvoiceReminders::SendJob do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
      end
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7")
    assert_predicate reminder, :status_failed?
    assert_equal "invalid recipient", reminder.failure_reason
  end

  test "ambiguous Gmail failure records failure without risking a duplicate retry" do
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver)
      .raises(EmailConnection::Errors::AmbiguousDeliveryError, "response lost")

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_enqueued_jobs only: InvoiceReminders::SendJob do
        InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
      end
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7")
    assert_predicate reminder, :status_failed?
    assert_equal "response lost", reminder.failure_reason
  end

  test "temporary Gmail failure retries with one pending delivery record" do
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver)
      .raises(EmailConnection::Errors::TemporaryDeliveryError, "rate limited")

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_difference [
        -> { @invoice.invoice_reminders.count },
        -> { @invoice.conversation_messages.count }
      ], 1 do
        assert_enqueued_jobs 1, only: InvoiceReminders::SendJob do
          InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
        end
      end
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7")
    assert_predicate reminder, :status_pending?
    assert_nil reminder.sent_at
    assert_nil reminder.failure_reason
  end

  test "a retry-safe provider error relinquishes the claim and the retry sends" do
    attempts = sequence("reminder-retry-safe-provider-error")
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver)
      .in_sequence(attempts)
      .raises(EmailConnection::Errors::TemporaryDeliveryError, "rate limited")
    EmailConnection::Gmail::Delivery.any_instance.expects(:deliver)
      .in_sequence(attempts)
      .returns(@delivery_result)

    travel_to Time.zone.local(2026, 7, 24, 12) do
      perform_enqueued_jobs(only: InvoiceReminders::SendJob) do
        InvoiceReminders::SendJob.perform_later(
          @invoice.id,
          "pre_due",
          7,
          "friendly"
        )
      end
    end

    message = @invoice.invoice_reminders
      .find_by!(stage_key: "pre_due_7")
      .conversation_message
    assert_predicate message, :status_sent?
    assert_equal "gmail-message-123", message.provider_message_id
  end

  test "preflight cleanup preserves uncertainty after a claimed delivery" do
    job = InvoiceReminders::SendJob.new(
      @invoice.id,
      "pre_due",
      7,
      "friendly"
    )
    reminder = nil
    travel_to Time.zone.local(2026, 7, 24, 12) do
      reservation = InvoiceReminders::DeliveryReservation.call(
        invoice: @invoice,
        category: :pre_due,
        day_offset: 7,
        delivery_job_id: job.job_id
      )
      reminder = reservation.reminder
      assert_predicate InvoiceReminders::FinalDeliveryClaim.call(
        invoice: @invoice,
        reminder:,
        delivery_job_id: job.job_id
      ), :claimed?
      CollectionHolds::Placement.call(
        conversation: Conversation.for_invoice!(invoice: @invoice),
        reason: :manual,
        placed_by_kind: :user,
        placed_by_user: users(:arjun),
        idempotency_key: "hold-after-reminder-provider-claim"
      )
      job.perform_now
    end

    message = reminder.conversation_message.reload
    assert_predicate message, :status_failed?
    assert_predicate message, :delivery_uncertain?
    assert_includes @invoice.conversation_messages
      .successful_outbound
      .sent_after(1.hour.ago), message
  end

  test "invoice state cleanup preserves uncertainty after a claimed delivery" do
    job = InvoiceReminders::SendJob.new(
      @invoice.id,
      "pre_due",
      7,
      "friendly"
    )
    reminder = nil
    travel_to Time.zone.local(2026, 7, 24, 12) do
      reservation = InvoiceReminders::DeliveryReservation.call(
        invoice: @invoice,
        category: :pre_due,
        day_offset: 7,
        delivery_job_id: job.job_id
      )
      reminder = reservation.reminder
      assert_predicate InvoiceReminders::FinalDeliveryClaim.call(
        invoice: @invoice,
        reminder:,
        delivery_job_id: job.job_id
      ), :claimed?
      @invoice.update!(status: :paid)

      job.perform_now
    end

    message = reminder.conversation_message.reload
    assert_predicate message, :status_failed?
    assert_predicate message, :delivery_uncertain?
  end

  test "exhausted cleanup distinguishes claimed from definitely unsent delivery" do
    claimed_job = InvoiceReminders::SendJob.new(
      @invoice.id,
      "pre_due",
      7,
      "friendly"
    )
    claimed = create_reminder(
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      status: :pending,
      delivery_job_id: claimed_job.job_id
    )
    claimed.conversation_message.update!(
      provider_delivery_started_at: Time.current
    )
    assert claimed_job.send(
      :record_exhausted_pending_failure,
      StandardError.new("claimed exhausted")
    )
    assert_predicate claimed.conversation_message.reload, :delivery_uncertain?

    other_invoice = create_stripe_invoice
    unsent_job = InvoiceReminders::SendJob.new(
      other_invoice.id,
      "pre_due",
      7,
      "friendly"
    )
    unsent = other_invoice.invoice_reminders.create!(
      account: other_invoice.account,
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      tone: :friendly,
      conversation_message: other_invoice.conversation_messages.create!(
        account: other_invoice.account,
        conversation: Conversation.for_invoice!(invoice: other_invoice),
        direction: :outbound,
        kind: :scheduled_reminder,
        status: :pending,
        delivery_job_id: unsent_job.job_id,
        delivery_attempted_at: Time.current
      )
    )
    assert unsent_job.send(
      :record_exhausted_pending_failure,
      StandardError.new("unsent exhausted")
    )
    assert_not_predicate unsent.conversation_message.reload, :delivery_uncertain?
  end

  test "a temporary-delivery retry reuses its pending message and reminder" do
    job = InvoiceReminders::SendJob.new(@invoice.id, "pre_due", 7, "friendly")
    reminder = create_reminder(
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      status: :pending,
      delivery_job_id: job.job_id
    )
    job.expects(:send_email).once.returns(@delivery_result)

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_difference -> { @invoice.invoice_reminders.count } do
        assert_no_difference -> { @invoice.conversation_messages.count } do
          job.perform_now
        end
      end
    end

    assert_equal reminder.id, @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7").id
    assert_predicate reminder.conversation_message.reload, :status_sent?
    assert_equal "gmail-message-123", reminder.provider_message_id
    assert_equal "gmail-thread-456", reminder.provider_thread_id
  end

  test "a duplicate initial job does not bypass a pending retry's backoff" do
    reminder = create_reminder(
      category: :pre_due,
      day_offset: 7,
      stage_key: "pre_due_7",
      status: :pending
    )
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end

    assert_predicate reminder.conversation_message.reload, :status_pending?
  end

  test "does not send a queued reminder after another outbound message contacts the invoice" do
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      create_message(kind: :invoice_resend, status: :sent, sent_at: Time.current)

      assert_no_difference -> { @invoice.invoice_reminders.count } do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end

      suppression = @invoice.invoice_reminder_suppressions.find_by!(stage_key: "pre_due_7")
      assert_predicate suppression, :reason_recent_outbound_message?
    end
  end

  test "does not send a queued reminder after the customer makes a payment promise" do
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(@invoice.id, "pre_due", 7, "friendly")
      source_message = create_message(
        direction: :inbound,
        kind: :customer_reply,
        status: :received,
        received_at: Time.current
      )
      PaymentPromise.record!(
        invoice: @invoice,
        source_message:,
        promised_on: Date.current + 2.days
      )

      assert_no_difference -> { @invoice.invoice_reminders.count } do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end

      suppression = @invoice.invoice_reminder_suppressions.find_by!(stage_key: "pre_due_7")
      assert_predicate suppression, :reason_active_payment_promise?
    end
  end

  test "does not refresh or send a queued reminder after a collection hold is placed" do
    InvoiceReminders::InvoiceFreshnessCheck.expects(:call).never
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_later(
        @invoice.id,
        "pre_due",
        7,
        "friendly"
      )
      CollectionHolds::Placement.call(
        conversation: Conversation.for_invoice!(invoice: @invoice),
        reason: :manual,
        placed_by_kind: :user,
        placed_by_user: users(:arjun),
        idempotency_key: "queued-reminder-hold"
      )

      perform_enqueued_jobs(only: InvoiceReminders::SendJob)
    end

    suppression = @invoice.invoice_reminder_suppressions.find_by!(
      stage_key: "pre_due_7"
    )
    assert_predicate suppression, :reason_active_collection_hold?
  end

  test "does not send a stage that was already suppressed" do
    schedule = invoice_schedules(:normal_pre_due_7)
    @invoice.invoice_reminder_suppressions.create!(
      account: @invoice.account,
      invoice_schedule: schedule,
      category: schedule.category,
      day_offset: schedule.day_offset,
      stage_key: schedule.key,
      reason: :recent_outbound_message,
      suppressed_at: Time.current
    )
    InvoiceReminders::SendJob.any_instance.expects(:send_email).never

    travel_to Time.zone.local(2026, 7, 24, 12) do
      InvoiceReminders::SendJob.perform_now(@invoice.id, "pre_due", 7, "friendly")
    end
  end

  test "exhausted temporary Gmail retries record a failed receipt" do
    EmailConnection::Gmail::Delivery.any_instance.stubs(:deliver)
      .raises(EmailConnection::Errors::TemporaryDeliveryError, "Gmail unavailable")
    job = InvoiceReminders::SendJob.new(@invoice.id, "pre_due", 7, "friendly")
    job.exception_executions[[ EmailConnection::Errors::TemporaryDeliveryError ].to_s] = 4

    travel_to Time.zone.local(2026, 7, 24, 12) do
      assert_no_enqueued_jobs only: InvoiceReminders::SendJob do
        job.perform_now
      end
    end

    reminder = @invoice.invoice_reminders.find_by!(stage_key: "pre_due_7")
    assert_predicate reminder, :status_failed?
    assert_equal "Gmail unavailable", reminder.failure_reason
  end

  private
    def create_reminder(
      category:,
      day_offset:,
      stage_key:,
      status:,
      sent_at: nil,
      delivery_job_id: nil
    )
      @invoice.invoice_reminders.create!(
        account: @invoice.account,
        category:,
        day_offset:,
        stage_key:,
        conversation_message: create_message(status:, sent_at:, delivery_job_id:)
      )
    end

    def create_message(
      direction: :outbound,
      kind: :scheduled_reminder,
      status:,
      sent_at: nil,
      received_at: nil,
      delivery_job_id: nil
    )
      @invoice.conversation_messages.create!(
        account: @invoice.account,
        conversation: Conversation.for_invoice!(invoice: @invoice),
        direction:,
        kind:,
        status:,
        sent_at:,
        received_at:,
        delivery_job_id:,
        to_addresses: [],
        cc_addresses: []
      )
    end

    def create_stripe_invoice
      source = @invoice.account.invoice_sources.create!(
        provider: :stripe,
        status: :active,
        external_account_id: "acct_payment_reminder"
      )
      customer = source.customers.create!(
        account: @invoice.account,
        customer_segment: customer_segments(:normal_debtor_segment),
        external_id: "cus_payment_reminder",
        name: "Stripe Customer",
        email: "stripe-customer@example.com"
      )

      source.invoices.create!(
        account: @invoice.account,
        customer:,
        external_id: "in_payment_reminder",
        number: "STRIPE-001",
        provider_status: "open",
        status: :open,
        currency: "USD",
        amount_due: 125,
        amount_paid: 0,
        total: 125,
        issued_on: Date.new(2026, 7, 1),
        due_on: Date.new(2026, 7, 31),
        synced_at: Time.current
      )
    end

    def subscribe_to(*events)
      user = users(:arjun)
      user.update!(
        identity: Identity.create!(email_address: "notifications@example.com"),
        verified_at: Time.current
      )
      events.each do |event|
        user.notification_subscriptions.create!(event:, email: true)
      end
      user
    end

    def replace_schedule(kind:, category:, day_offset:, tone:)
      @invoice.account.invoice_schedules.where(kind:, category:, day_offset:).delete_all
      @invoice.account.invoice_schedules.create!(kind:, category:, day_offset:, tone:)
    end
end

require "test_helper"

class InvoiceReminders::SendJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @invoice = invoices(:xero_invoice)
    @invoice.account.update!(automatic_invoice_reminders_enabled: true)
  end

  test "limits concurrency to one job for each invoice stage" do
    first_job = InvoiceReminders::SendJob.new(@invoice.id, "pre_due", 7, "friendly")
    same_stage_job = InvoiceReminders::SendJob.new(@invoice.id, "pre_due", 7, "final")
    other_invoice_job = InvoiceReminders::SendJob.new(@invoice.id + 1, "pre_due", 7, "friendly")
    other_stage_job = InvoiceReminders::SendJob.new(@invoice.id, "overdue", 3, "direct")

    assert_predicate first_job, :concurrency_limited?
    assert_equal "InvoiceReminders::SendJob/#{@invoice.id}:pre_due_7", first_job.concurrency_key
    assert_equal first_job.concurrency_key, same_stage_job.concurrency_key
    refute_equal first_job.concurrency_key, other_invoice_job.concurrency_key
    refute_equal first_job.concurrency_key, other_stage_job.concurrency_key
    assert_equal 1, InvoiceReminders::SendJob.concurrency_limit
    assert_equal 1.hour, InvoiceReminders::SendJob.concurrency_duration
    assert_equal :block, InvoiceReminders::SendJob.concurrency_on_conflict
  end

  test "a duplicate job released after delivery does not send again" do
    InvoiceReminders::SendJob.any_instance.expects(:send_email).once.returns(true)

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

  test "creates a sent receipt after sending the email" do
    sent_at = Time.zone.local(2026, 7, 24, 12)

    travel_to sent_at do
      assert_no_emails do
        assert_difference -> { @invoice.invoice_reminders.count }, 1 do
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
    assert_nil reminder.failure_reason
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
    @invoice.invoice_reminders.create!(
      account: @invoice.account,
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
      InvoiceReminders::SendJob.any_instance.expects(:send_email).with(
        invoice: @invoice,
        stage_key: "pre_due_7",
        tone: "direct"
      ).returns(true)

      assert_difference -> { @invoice.invoice_reminders.count }, 1 do
        perform_enqueued_jobs(only: InvoiceReminders::SendJob)
      end
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
      InvoiceReminders::SendJob.any_instance.expects(:send_email).with(
        invoice: @invoice,
        stage_key: "pre_due_7",
        tone: "firm"
      ).returns(true)

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
    job = InvoiceReminders::SendJob.new(@invoice.id, "pre_due", 7, "friendly")
    job.define_singleton_method(:send_email) do |**|
      schedule.destroy!
      true
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
    InvoiceReminders::SendJob.any_instance.expects(:send_email).with(
      invoice: @invoice,
      stage_key: "pre_due_7",
      tone: "friendly"
    ).returns(true)

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
    @invoice.invoice_reminders.create!(
      account: @invoice.account,
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

  private
    def subscribe_to(*events)
      user = users(:arjun)
      user.update!(identity: Identity.create!(email_address: "notifications@example.com"))
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

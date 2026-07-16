require "test_helper"

class Invoice::RemindableTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @invoice.update!(due_on: Date.new(2026, 11, 1))
  end

  test "returns the next future stage for the customer's current rating" do
    @invoice.customer.update!(customer_segment: customer_segments(:good_debtor_segment))

    travel_to Time.zone.local(2026, 11, 8, 12) do
      stage = @invoice.next_reminder_stage

      assert_equal "overdue_10", stage.key
      assert_equal :final, stage.tone
    end
  end

  test "returns nil when the final stage has passed" do
    @invoice.customer.update!(customer_segment: customer_segments(:good_debtor_segment))

    travel_to Time.zone.local(2026, 11, 20, 12) do
      assert_nil @invoice.next_reminder_stage
    end
  end

  test "returns a stage scheduled for today" do
    @invoice.customer.update!(customer_segment: customer_segments(:good_debtor_segment))

    travel_to Time.zone.local(2026, 11, 4, 12) do
      stage = @invoice.next_reminder_stage

      assert_equal "overdue_3", stage.key
    end
  end

  test "returns the next stage after the latest reminder was sent" do
    create_reminder(stage_key: "pre_due_7", status: :sent)

    travel_to Time.zone.local(2026, 10, 25, 12) do
      stage = @invoice.next_reminder_stage

      assert_equal "pre_due_1", stage.key
    end
  end

  test "continues from the current reminder using the customer's current rating" do
    create_reminder(stage_key: "pre_due_7", status: :sent)
    @invoice.customer.update!(customer_segment: customer_segments(:good_debtor_segment))

    travel_to Time.zone.local(2026, 10, 25, 12) do
      stage = @invoice.next_reminder_stage

      assert_equal "pre_due_3", stage.key
    end
  end

  test "does not repeat an exact stage that was already sent" do
    @invoice.customer.update!(customer_segment: customer_segments(:bad_debtor_segment))
    create_reminder(stage_key: "pre_due_3", status: :sent)

    travel_to Time.zone.local(2026, 10, 29, 12) do
      stage = @invoice.next_reminder_stage

      assert_equal "pre_due_1", stage.key
    end
  end

  test "returns nil while the latest reminder is not sent" do
    travel_to Time.zone.local(2026, 10, 25, 12) do
      %i[pending processing failed skipped].each do |status|
        reminder = create_reminder(stage_key: "pre_due_7", status:)

        assert_nil @invoice.next_reminder_stage, status

        reminder.destroy!
      end
    end
  end

  test "uses the reminder with the latest scheduled time to decide whether to proceed" do
    create_reminder(stage_key: "pre_due_7", status: :pending)
    create_reminder(stage_key: "pre_due_1", status: :sent)

    travel_to Time.zone.local(2026, 10, 20, 12) do
      stage = @invoice.next_reminder_stage

      assert_equal "overdue_3", stage.key
    end
  end

  test "returns nil without a due date" do
    @invoice.update!(due_on: nil)

    assert_nil @invoice.next_reminder_stage
  end

  test "returns nil for an invoice that is no longer outstanding" do
    @invoice.update!(status: :paid, amount_due: 0, amount_paid: 125, paid_on: Date.new(2026, 10, 30))

    assert_nil @invoice.next_reminder_stage
  end

  test "returns the current invoice reminder by scheduled time" do
    create_reminder(stage_key: "pre_due_7", status: :sent)
    current_reminder = create_reminder(stage_key: "pre_due_1", status: :pending)

    assert_equal current_reminder, @invoice.current_invoice_reminder
  end

  test "returns the current invoice reminder date" do
    assert_nil @invoice.current_invoice_reminder_date

    create_reminder(stage_key: "pre_due_7", status: :sent)
    create_reminder(stage_key: "pre_due_1", status: :pending)

    assert_equal Date.new(2026, 10, 31), @invoice.current_invoice_reminder_date
  end

  test "returns the date for the next reminder stage" do
    travel_to Time.zone.local(2026, 10, 20, 12) do
      assert_equal Date.new(2026, 10, 25), @invoice.next_invoice_reminder_date
    end

    create_reminder(stage_key: "pre_due_7", status: :sent)

    travel_to Time.zone.local(2026, 10, 20, 12) do
      assert_equal Date.new(2026, 10, 31), @invoice.next_invoice_reminder_date
    end

    travel_to Time.zone.local(2026, 11, 20, 12) do
      assert_equal Date.new(2026, 10, 31), @invoice.next_invoice_reminder_date
    end
  end

  test "sets the next invoice reminder" do
    scheduled_at = Time.zone.local(2026, 10, 25, 9, 30)

    travel_to Time.zone.local(2026, 10, 20, 12) do
      assert_difference "@invoice.invoice_reminders.count", 1 do
        reminder = @invoice.set_next_invoice_reminder(scheduled_at:)

        assert_equal @invoice.account, reminder.account
        assert_equal @invoice, reminder.invoice
        assert_predicate reminder, :category_pre_due?
        assert_equal 7, reminder.day_offset
        assert_equal "pre_due_7", reminder.stage_key
        assert_predicate reminder, :status_pending?
        assert_equal scheduled_at, reminder.scheduled_at
      end
    end
  end

  test "sets the stage after a sent invoice reminder" do
    create_reminder(stage_key: "pre_due_7", status: :sent)
    scheduled_at = Time.zone.local(2026, 10, 31, 9, 30)

    reminder = @invoice.set_next_invoice_reminder(scheduled_at:)

    assert_equal "pre_due_1", reminder.stage_key
    assert_equal scheduled_at, reminder.scheduled_at
  end

  test "does not set another reminder while the new reminder is pending" do
    scheduled_at = Time.zone.local(2026, 10, 25, 9, 30)

    travel_to Time.zone.local(2026, 10, 20, 12) do
      first_reminder = @invoice.set_next_invoice_reminder(scheduled_at:)

      assert_no_difference "@invoice.invoice_reminders.count" do
        assert_nil @invoice.set_next_invoice_reminder(scheduled_at: scheduled_at + 1.hour)
      end

      assert_predicate first_reminder, :status_pending?
    end
  end

  test "does not set an invoice reminder when no next stage exists" do
    @invoice.customer.update!(customer_segment: customer_segments(:good_debtor_segment))

    travel_to Time.zone.local(2026, 11, 20, 12) do
      assert_no_difference "@invoice.invoice_reminders.count" do
        assert_nil @invoice.set_next_invoice_reminder(
          scheduled_at: Time.zone.local(2026, 11, 20, 9, 30)
        )
      end
    end
  end

  private
    def create_reminder(stage_key:, status:)
      category, day_offset = stage_key.rpartition("_").values_at(0, 2)
      stage = InvoiceReminder::Policy.stages_for(
        payer_segment: @invoice.customer.payer_segment
      ).find { |candidate| candidate.key == stage_key }

      @invoice.invoice_reminders.create!(
        account: @invoice.account,
        category:,
        stage_key:,
        day_offset:,
        status:,
        scheduled_at: stage.date_for(due_on: @invoice.due_on).in_time_zone
      )
    end
end

require "test_helper"

class InvoiceReminderTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
  end

  test "belongs to an account and invoice" do
    reminder = build_reminder

    assert_equal @invoice.account, reminder.account
    assert_equal @invoice, reminder.invoice
  end

  test "records a sent reminder receipt by default" do
    reminder = build_reminder

    assert reminder.save
    assert_predicate reminder, :category_pre_due?
    assert_predicate reminder, :status_sent?
  end

  test "records a failed reminder receipt" do
    reminder = build_reminder(status: :failed, failure_reason: "delivery failed")

    assert reminder.save
    assert_predicate reminder, :status_failed?
    assert_equal "delivery failed", reminder.failure_reason
  end

  test "accepts every supported delivery tone" do
    InvoiceReminder::TONES.values.each do |tone|
      assert build_reminder(tone:).valid?, "Expected #{tone} to be valid"
    end
  end

  test "allows legacy receipts without a delivery tone" do
    assert build_reminder(tone: nil).valid?
  end

  test "allows legacy receipts without an invoice schedule" do
    assert build_reminder(invoice_schedule: nil).valid?
  end

  test "rejects an unsupported delivery tone" do
    reminder = build_reminder(tone: "urgent")

    assert_not reminder.valid?
    assert_includes reminder.errors[:tone], "is not included in the list"
  end

  test "requires a valid category status and stage" do
    reminder = build_reminder(
      category: "other",
      status: "other",
      stage_key: nil,
      day_offset: 0
    )

    assert_not reminder.valid?
    assert_includes reminder.errors[:category], "is not included in the list"
    assert_includes reminder.errors[:status], "is not included in the list"
    assert_includes reminder.errors[:stage_key], "can't be blank"
    assert_includes reminder.errors[:day_offset], "must be greater than 0"
  end

  test "allows each stage only once per invoice" do
    build_reminder.save!
    duplicate = build_reminder

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:stage_key], "has already been taken"
  end

  test "requires the stage key to match its category and day offset" do
    reminder = build_reminder(stage_key: "overdue_3")

    assert_not reminder.valid?
    assert_includes reminder.errors[:stage_key], "must match category and day offset"
  end

  test "allows the same stage for another invoice" do
    build_reminder.save!
    other_invoice = @invoice.dup
    other_invoice.external_id = "invoice-reminder-other-invoice"
    other_invoice.save!

    assert build_reminder(invoice: other_invoice).valid?
  end

  test "requires its account to match its invoice account" do
    reminder = build_reminder(account: Account.create!(name: "Other Reminder Account"))

    assert_not reminder.valid?
    assert_includes reminder.errors[:account], "must match invoice account"
  end

  test "requires its invoice schedule to belong to the same account" do
    other_account = Account.create!(name: "Other Schedule Receipt Account")
    other_schedule = other_account.invoice_schedules.first
    reminder = build_reminder(invoice_schedule: other_schedule)

    assert_not reminder.valid?
    assert_includes reminder.errors[:invoice_schedule], "must belong to the same account"
  end

  test "allows one receipt per persisted schedule after its timing changes" do
    schedule = invoice_schedules(:normal_pre_due_7)
    build_reminder(invoice_schedule: schedule).save!
    schedule.update!(day_offset: 6)
    duplicate = build_reminder(
      invoice_schedule: schedule,
      stage_key: "pre_due_6",
      day_offset: 6
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:invoice_schedule_id], "has already been taken"
  end

  test "enforces stage uniqueness in the database" do
    build_reminder.save!

    assert_raises ActiveRecord::RecordNotUnique do
      build_reminder.save!(validate: false)
    end
  end

  private
    def build_reminder(attributes = {})
      InvoiceReminder.new(
        {
          account: @invoice.account,
          invoice: @invoice,
          category: :pre_due,
          stage_key: "pre_due_7",
          day_offset: 7
        }.merge(attributes)
      )
    end
end

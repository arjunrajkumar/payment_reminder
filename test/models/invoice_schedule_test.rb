require "test_helper"

class InvoiceScheduleTest < ActiveSupport::TestCase
  setup do
    @schedule = invoice_schedules(:normal_pre_due_7)
  end

  test "belongs to an account" do
    assert_equal accounts(:paid_jar), @schedule.account
  end

  test "defines payer segment kinds" do
    assert_equal CustomerSegment::PAYER_SEGMENTS, InvoiceSchedule::KINDS
    assert_predicate @schedule, :kind_normal_debtor?
  end

  test "defines reminder categories" do
    assert_equal InvoiceReminder::CATEGORIES, InvoiceSchedule::CATEGORIES
    assert_predicate @schedule, :category_pre_due?
  end

  test "defines reminder tones" do
    assert_equal InvoiceReminder::TONES, InvoiceSchedule::TONES
    assert_predicate @schedule, :tone_friendly?
  end

  test "requires a supported kind category tone and positive day offset" do
    @schedule.assign_attributes(
      kind: "unknown_debtor",
      category: "on_due",
      tone: "urgent",
      day_offset: 0
    )

    assert_not @schedule.valid?
    assert_includes @schedule.errors[:kind], "is not included in the list"
    assert_includes @schedule.errors[:category], "is not included in the list"
    assert_includes @schedule.errors[:tone], "is not included in the list"
    assert_includes @schedule.errors[:day_offset], "must be greater than 0"
  end

  test "requires a whole-number day offset" do
    @schedule.day_offset = 2.5

    assert_not @schedule.valid?
    assert_includes @schedule.errors[:day_offset], "must be an integer"
  end

  test "does not duplicate a stage within an account and payer segment" do
    duplicate = InvoiceSchedule.new(
      account: @schedule.account,
      kind: @schedule.kind,
      category: @schedule.category,
      day_offset: @schedule.day_offset,
      tone: :direct
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:day_offset], "has already been taken"
  end

  test "allows the same stage for another account" do
    other_account = Account.create!(name: "Other Schedule Account")
    other_schedule = other_account.invoice_schedules.find_by!(
      kind: @schedule.kind,
      category: @schedule.category,
      day_offset: @schedule.day_offset
    )

    assert_predicate other_schedule, :valid?
  end

  test "derives a stable stage key" do
    assert_equal "pre_due_7", @schedule.key
  end

  test "calculates a reminder date from an invoice due date" do
    due_on = Date.new(2026, 7, 31)

    assert_equal Date.new(2026, 7, 24), @schedule.date_for(due_on:)
    assert_equal Date.new(2026, 8, 14), invoice_schedules(:normal_overdue_14).date_for(due_on:)
  end

  test "calculates an invoice due date from a reminder date" do
    reminder_on = Date.new(2026, 7, 24)

    assert_equal Date.new(2026, 7, 31), @schedule.invoice_due_on_for(reminder_on:)
    assert_equal Date.new(2026, 7, 10),
      invoice_schedules(:normal_overdue_14).invoice_due_on_for(reminder_on:)
  end

  test "identifies the last chronological stage as terminal independently of tone" do
    terminal_stage = invoice_schedules(:normal_overdue_14)
    terminal_stage.update!(tone: :firm)

    assert_predicate terminal_stage, :terminal?
    assert_not_predicate @schedule, :terminal?
  end

  test "a newly added later stage becomes terminal" do
    previous_terminal = invoice_schedules(:normal_overdue_14)
    later_stage = @schedule.account.invoice_schedules.create!(
      kind: :normal_debtor,
      category: :overdue,
      day_offset: 21,
      tone: :direct
    )

    assert_predicate later_stage, :terminal?
    assert_not_predicate previous_terminal, :terminal?
  end
end

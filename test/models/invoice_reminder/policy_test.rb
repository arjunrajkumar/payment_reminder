require "test_helper"

class InvoiceReminder::PolicyTest < ActiveSupport::TestCase
  test "defines the good debtor schedule" do
    assert_equal(
      [
        [ "pre_due_3", :pre_due, 3, :friendly ],
        [ "overdue_3", :overdue, 3, :neutral ],
        [ "overdue_10", :overdue, 10, :final ]
      ],
      schedule_for(:good_debtor)
    )
  end

  test "defines the normal debtor schedule" do
    assert_equal(
      [
        [ "pre_due_7", :pre_due, 7, :friendly ],
        [ "pre_due_1", :pre_due, 1, :direct ],
        [ "overdue_3", :overdue, 3, :direct ],
        [ "overdue_7", :overdue, 7, :firm ],
        [ "overdue_14", :overdue, 14, :final ]
      ],
      schedule_for(:normal_debtor)
    )
  end

  test "defines the bad debtor schedule" do
    assert_equal(
      [
        [ "pre_due_14", :pre_due, 14, :direct ],
        [ "pre_due_7", :pre_due, 7, :direct ],
        [ "pre_due_3", :pre_due, 3, :direct ],
        [ "pre_due_1", :pre_due, 1, :direct ],
        [ "overdue_1", :overdue, 1, :firm ],
        [ "overdue_5", :overdue, 5, :final ]
      ],
      schedule_for(:bad_debtor)
    )
  end

  test "accepts a persisted payer segment string" do
    stages = InvoiceReminder::Policy.stages_for(payer_segment: "good_debtor")

    assert_equal "pre_due_3", stages.first.key
  end

  test "calculates stage dates from an invoice due date" do
    due_on = Date.new(2026, 7, 31)
    stages = InvoiceReminder::Policy.stages_for(payer_segment: :normal_debtor).index_by(&:key)

    assert_equal Date.new(2026, 7, 24), stages.fetch("pre_due_7").date_for(due_on:)
    assert_equal Date.new(2026, 8, 14), stages.fetch("overdue_14").date_for(due_on:)
  end

  test "calculates target invoice due dates from the reminder date" do
    reminder_on = Date.new(2026, 7, 24)
    stages = InvoiceReminder::Policy.stages_for(payer_segment: :normal_debtor).index_by(&:key)

    assert_equal Date.new(2026, 7, 31), stages.fetch("pre_due_7").invoice_due_on_for(reminder_on:)
    assert_equal Date.new(2026, 7, 10), stages.fetch("overdue_14").invoice_due_on_for(reminder_on:)
  end

  test "returns an immutable schedule" do
    stages = InvoiceReminder::Policy.stages_for(payer_segment: :good_debtor)

    assert_predicate stages, :frozen?
    assert_raises(FrozenError) { stages << stages.first }
  end

  test "rejects an unknown payer segment" do
    assert_raises KeyError do
      InvoiceReminder::Policy.stages_for(payer_segment: :unknown)
    end
  end

  private
    def schedule_for(payer_segment)
      InvoiceReminder::Policy.stages_for(payer_segment:).map do |stage|
        [ stage.key, stage.category, stage.day_offset, stage.tone ]
      end
    end
end

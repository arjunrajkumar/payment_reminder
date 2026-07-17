class CreateInvoiceSchedules < ActiveRecord::Migration[8.1]
  DEFAULT_SCHEDULES = {
    good_debtor: [
      [ :pre_due, 3, :friendly ],
      [ :overdue, 3, :neutral ],
      [ :overdue, 10, :final ]
    ],
    normal_debtor: [
      [ :pre_due, 7, :friendly ],
      [ :pre_due, 1, :direct ],
      [ :overdue, 3, :direct ],
      [ :overdue, 7, :firm ],
      [ :overdue, 14, :final ]
    ],
    bad_debtor: [
      [ :pre_due, 14, :direct ],
      [ :pre_due, 7, :direct ],
      [ :pre_due, 3, :direct ],
      [ :pre_due, 1, :direct ],
      [ :overdue, 1, :firm ],
      [ :overdue, 5, :final ]
    ]
  }.freeze

  class MigrationInvoiceSchedule < ActiveRecord::Base
    self.table_name = "invoice_schedules"
  end

  class MigrationAccount < ActiveRecord::Base
    self.table_name = "accounts"
  end

  def change
    create_table :invoice_schedules do |t|
      t.references :account, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :category, null: false
      t.integer :day_offset, null: false
      t.string :tone, null: false
      t.timestamps
    end

    add_index :invoice_schedules,
      %i[account_id kind category day_offset],
      unique: true,
      name: "index_invoice_schedules_on_account_and_stage"
    add_check_constraint :invoice_schedules,
      "day_offset > 0",
      name: "invoice_schedules_day_offset_positive"

    reversible do |direction|
      direction.up { backfill_default_schedules }
    end
  end

  private
    def backfill_default_schedules
      MigrationInvoiceSchedule.reset_column_information

      MigrationAccount.in_batches(of: 500) do |accounts|
        now = Time.current
        rows = accounts.ids.flat_map do |account_id|
          DEFAULT_SCHEDULES.flat_map do |kind, stages|
            stages.map do |category, day_offset, tone|
              {
                account_id:,
                kind: kind.to_s,
                category: category.to_s,
                day_offset:,
                tone: tone.to_s,
                created_at: now,
                updated_at: now
              }
            end
          end
        end

        MigrationInvoiceSchedule.insert_all!(rows)
      end
    end
end

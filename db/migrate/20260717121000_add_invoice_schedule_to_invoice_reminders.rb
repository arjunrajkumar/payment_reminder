class AddInvoiceScheduleToInvoiceReminders < ActiveRecord::Migration[8.1]
  class MigrationInvoiceReminder < ActiveRecord::Base
    self.table_name = "invoice_reminders"
  end

  class MigrationInvoiceSchedule < ActiveRecord::Base
    self.table_name = "invoice_schedules"
  end

  def change
    add_reference :invoice_reminders,
      :invoice_schedule,
      foreign_key: { on_delete: :nullify }
    add_index :invoice_reminders,
      %i[invoice_id invoice_schedule_id],
      unique: true,
      name: "index_invoice_reminders_on_invoice_and_schedule"

    reversible do |direction|
      direction.up { backfill_unambiguous_schedule_references }
    end
  end

  private
    def backfill_unambiguous_schedule_references
      MigrationInvoiceReminder.reset_column_information

      MigrationInvoiceReminder.where(invoice_schedule_id: nil).in_batches(of: 500) do |batch|
        receipts = batch.to_a
        schedules_by_account = MigrationInvoiceSchedule
          .where(account_id: receipts.map(&:account_id).uniq)
          .to_a
          .group_by(&:account_id)

        receipts.each do |receipt|
          matches = matching_schedules(receipt:, schedules_by_account:)
          receipt.update_column(:invoice_schedule_id, matches.first.id) if matches.one?
        end
      end
    end

    def matching_schedules(receipt:, schedules_by_account:)
      schedules_by_account.fetch(receipt.account_id, []).select do |schedule|
        schedule.category == receipt.category &&
          schedule.day_offset == receipt.day_offset &&
          (receipt.tone.blank? || schedule.tone == receipt.tone)
      end
    end
end

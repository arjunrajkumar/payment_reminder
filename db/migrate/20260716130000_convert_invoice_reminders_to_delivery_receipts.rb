class ConvertInvoiceRemindersToDeliveryReceipts < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DELETE FROM invoice_reminders
      WHERE status NOT IN ('sent', 'failed')
    SQL

    remove_column :invoice_reminders, :scheduled_at, :datetime
    change_column_default :invoice_reminders, :status, from: "pending", to: "sent"
  end

  def down
    add_column :invoice_reminders, :scheduled_at, :datetime
    execute <<~SQL
      UPDATE invoice_reminders
      SET scheduled_at = created_at
    SQL
    change_column_null :invoice_reminders, :scheduled_at, false
    change_column_default :invoice_reminders, :status, from: "sent", to: "pending"
  end
end

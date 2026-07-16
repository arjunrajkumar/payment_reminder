class CreateInvoiceReminders < ActiveRecord::Migration[8.1]
  def change
    create_table :invoice_reminders do |t|
      t.references :account, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.string :category, null: false
      t.string :stage_key, null: false
      t.integer :day_offset, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :scheduled_at, null: false
      t.datetime :sent_at
      t.text :failure_reason
      t.timestamps
    end

    add_index :invoice_reminders, [ :invoice_id, :stage_key ], unique: true
  end
end

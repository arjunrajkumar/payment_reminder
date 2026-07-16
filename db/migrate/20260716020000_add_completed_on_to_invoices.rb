class AddCompletedOnToInvoices < ActiveRecord::Migration[8.1]
  def change
    add_column :invoices, :completed_on, :date
    add_index :invoices, [ :customer_id, :completed_on ]
  end
end

class NormalizeInvoiceStatuses < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_invoices_on_account_id_and_status"

  def up
    remove_index :invoices, name: INDEX_NAME
    rename_column :invoices, :status, :provider_status
    add_column :invoices, :status, :string, null: false, default: "unknown"
    add_index :invoices, [ :account_id, :status ], name: INDEX_NAME
  end

  def down
    remove_index :invoices, name: INDEX_NAME
    remove_column :invoices, :status
    rename_column :invoices, :provider_status, :status
    add_index :invoices, [ :account_id, :status ], name: INDEX_NAME
  end
end

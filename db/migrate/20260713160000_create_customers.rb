class CreateCustomers < ActiveRecord::Migration[8.1]
  def up
    create_table :customers do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :invoice_source, null: false, foreign_key: true, index: false
      t.string :external_id, null: false
      t.string :name, null: false
      t.string :email
      t.datetime :details_observed_at

      t.timestamps

      t.index [ :invoice_source_id, :external_id ], unique: true
      t.index [ :account_id, :name ]
    end

    add_reference :invoices, :customer, foreign_key: true
  end

  def down
    remove_foreign_key :invoices, :customers if foreign_key_exists?(:invoices, :customers)
    remove_index :invoices, :customer_id if index_exists?(:invoices, :customer_id)
    remove_column :invoices, :customer_id if column_exists?(:invoices, :customer_id)
    drop_table :customers
  end
end

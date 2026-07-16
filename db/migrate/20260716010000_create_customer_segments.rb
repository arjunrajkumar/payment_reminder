class CreateCustomerSegments < ActiveRecord::Migration[8.1]
  def up
    create_table :customer_segments do |t|
      t.references :account, null: false, foreign_key: true
      t.string :payer_segment, null: false
      t.integer :on_time_rate
      t.timestamps
    end
    add_index :customer_segments, [ :account_id, :payer_segment ], unique: true

    add_reference :customers, :customer_segment, null: false, foreign_key: true
    add_index :customers, [ :account_id, :customer_segment_id ]
    remove_index :customers, name: "index_customers_on_account_id_and_payer_segment"
    remove_column :customers, :payer_segment

    remove_column :accounts, :payer_segment_minimum_payment_history
    remove_column :accounts, :payer_segment_minimum_unreliable_history
    remove_column :accounts, :payer_segment_pays_on_time_rate
    remove_column :accounts, :payer_segment_unreliable_on_time_rate
    remove_column :accounts, :payer_segment_slow_payer_days
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Customer segment configuration is not restored by this migration"
  end
end

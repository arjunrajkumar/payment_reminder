class RemoveReceivablesAndMovePayerSegmentsToCustomers < ActiveRecord::Migration[8.1]
  def up
    add_column :customers, :payer_segment, :string, null: false, default: "new"
    add_index :customers, [ :account_id, :payer_segment ]

    execute <<~SQL
      UPDATE customers
      INNER JOIN receivables
        ON receivables.customer_id = customers.id
        AND receivables.account_id = customers.account_id
      SET customers.payer_segment = receivables.payer_segment
    SQL

    drop_table :receivables
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Receivable rows cannot be reconstructed after they have been removed"
  end
end

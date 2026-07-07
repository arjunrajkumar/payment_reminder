class CreateInvoiceEventsAndStates < ActiveRecord::Migration[8.1]
  def change
    create_table :invoice_events do |t|
      t.references :invoice, null: false, foreign_key: true
      t.string :situation, null: false
      t.datetime :asked_at, null: false
      t.text :summary
      t.text :highlight
      t.string :response
      t.datetime :responded_at
      t.string :source
      t.string :source_message_id
      t.json :metadata, null: false

      t.timestamps
    end

    add_index :invoice_events, [ :invoice_id, :asked_at ]
    add_index :invoice_events, [ :invoice_id, :situation ]
    add_index :invoice_events, :source_message_id

    create_table :invoice_states do |t|
      t.references :invoice, null: false, foreign_key: true, index: { unique: true }
      t.references :latest_invoice_event, foreign_key: { to_table: :invoice_events }
      t.string :customer_situation, null: false
      t.datetime :customer_situation_at, null: false
      t.string :latest_response
      t.datetime :latest_response_at
      t.text :highlight
      t.string :next_step
      t.datetime :next_step_at

      t.timestamps
    end
  end
end

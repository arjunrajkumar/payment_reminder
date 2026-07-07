class CreateInvoiceSourceWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :invoice_source_webhook_events do |t|
      t.references :invoice_source, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :provider_event_id, null: false
      t.string :event_type, null: false
      t.string :resource_type
      t.string :resource_id
      t.datetime :occurred_at
      t.json :payload, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :processed_at
      t.text :last_error

      t.timestamps
    end

    add_index :invoice_source_webhook_events, [ :invoice_source_id, :provider_event_id ], unique: true
    add_index :invoice_source_webhook_events, [ :invoice_source_id, :status ]
    add_index :invoice_source_webhook_events, :occurred_at
  end
end

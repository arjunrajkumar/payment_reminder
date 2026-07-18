class CreateOutboundEmailConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :outbound_email_connections do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.string :provider, null: false
      t.string :connected_email, null: false
      t.string :provider_display_name
      t.text :access_token
      t.text :refresh_token
      t.datetime :token_expires_at
      t.json :scopes, null: false
      t.string :status, null: false, default: "pending"
      t.text :last_error
      t.timestamps
    end

    add_index :outbound_email_connections, %i[provider status]
    add_column :accounts, :invoice_reminder_from_name, :string
    add_column :invoice_reminders, :provider_message_id, :string

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE accounts
          SET automatic_invoice_reminders_enabled = FALSE
          WHERE automatic_invoice_reminders_enabled = TRUE
        SQL
      end
    end
  end
end

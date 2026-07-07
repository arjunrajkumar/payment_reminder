class CreateAccountingIntegrationsAndInvoices < ActiveRecord::Migration[8.1]
  def change
    drop_table :xero_connections, if_exists: true
    drop_table :invoice_integrations, if_exists: true

    create_table :accounting_integrations do |t|
      t.references :account, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :status, null: false, default: "pending"
      t.string :external_account_id, null: false
      t.string :external_account_name
      t.text :access_token
      t.text :refresh_token
      t.datetime :expires_at
      t.json :scopes, null: false
      t.json :provider_data, null: false
      t.json :raw_token_data, null: false
      t.datetime :last_synced_at
      t.text :last_error

      t.timestamps
    end

    add_index :accounting_integrations, [ :account_id, :provider ], unique: true
    add_index :accounting_integrations, [ :provider, :status ]

    create_table :invoices do |t|
      t.references :account, null: false, foreign_key: true
      t.references :accounting_integration, null: false, foreign_key: true
      t.string :external_id, null: false
      t.string :number
      t.string :invoice_type
      t.string :status
      t.string :currency
      t.decimal :amount_due, precision: 12, scale: 2
      t.decimal :amount_paid, precision: 12, scale: 2
      t.decimal :total, precision: 12, scale: 2
      t.date :issued_on
      t.date :due_on
      t.string :contact_external_id
      t.string :contact_name
      t.json :provider_data, null: false
      t.json :raw_data, null: false
      t.datetime :synced_at

      t.timestamps
    end

    add_index :invoices, [ :accounting_integration_id, :external_id ], unique: true
    add_index :invoices, [ :account_id, :status ]
    add_index :invoices, :due_on
  end
end

class CreateInvoiceIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :invoice_integrations do |t|
      t.references :account, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :status, null: false, default: "pending"
      t.string :external_account_id, null: false
      t.string :external_account_name
      t.text :access_token
      t.text :refresh_token
      t.datetime :expires_at
      t.json :scopes, null: false, default: []
      t.json :provider_data, null: false, default: {}
      t.json :raw_token_data, null: false, default: {}
      t.datetime :last_synced_at
      t.text :last_error

      t.timestamps
    end

    add_index :invoice_integrations, [ :account_id, :provider, :external_account_id ], unique: true
    add_index :invoice_integrations, [ :provider, :status ]
  end
end

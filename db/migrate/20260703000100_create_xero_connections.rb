class CreateXeroConnections < ActiveRecord::Migration[8.0]
  def change
    create_table :xero_connections do |t|
      t.string :xero_user_id
      t.string :email
      t.string :tenant_id
      t.string :tenant_name
      t.text :access_token, null: false
      t.text :refresh_token, null: false
      t.text :id_token
      t.string :token_type, null: false
      t.json :scopes, null: false, default: []
      t.datetime :expires_at, null: false
      t.json :connections, null: false, default: []
      t.json :raw_token_set, null: false, default: {}
      t.json :raw_userinfo, null: false, default: {}

      t.timestamps
    end

    add_index :xero_connections, :tenant_id
    add_index :xero_connections, :xero_user_id
  end
end

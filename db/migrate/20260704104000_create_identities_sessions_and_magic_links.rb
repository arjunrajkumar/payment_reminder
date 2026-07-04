class CreateIdentitiesSessionsAndMagicLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :identities do |t|
      t.string :email_address, null: false

      t.timestamps
    end

    create_table :sessions do |t|
      t.references :identity, null: false, foreign_key: true
      t.string :user_agent
      t.string :ip_address

      t.timestamps
    end

    create_table :magic_links do |t|
      t.references :identity, null: false, foreign_key: true
      t.string :code, null: false
      t.datetime :expires_at, null: false
      t.integer :purpose, null: false

      t.timestamps
    end

    add_reference :users, :identity, foreign_key: true
    add_column :users, :role, :string, null: false, default: "member"
    add_column :users, :verified_at, :datetime
    add_index :identities, :email_address, unique: true
    add_index :users, [ :account_id, :identity_id ], unique: true
    add_index :users, [ :account_id, :role ]
    add_index :magic_links, :code, unique: true
    add_index :magic_links, :expires_at
  end
end

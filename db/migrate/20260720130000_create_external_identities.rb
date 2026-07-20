class CreateExternalIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :external_identities do |t|
      t.references :identity, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider, null: false
      t.string :subject, null: false, collation: "utf8mb4_0900_bin"
      t.string :email_address

      t.timestamps

      t.index %i[provider subject], unique: true
      t.index %i[identity_id provider], unique: true
    end

    add_index :invoice_sources, %i[provider external_account_id], unique: true
  end
end

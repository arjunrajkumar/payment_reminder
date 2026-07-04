class CreateAccountsAndUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts do |t|
      t.bigint :external_account_id
      t.string :name, null: false

      t.timestamps
    end

    create_table :users do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false

      t.timestamps
    end

    add_index :accounts, :external_account_id, unique: true
    add_index :accounts, :name
  end
end

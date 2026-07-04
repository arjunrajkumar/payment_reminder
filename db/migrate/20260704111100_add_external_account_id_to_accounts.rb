class AddExternalAccountIdToAccounts < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:accounts, :external_account_id)
      add_column :accounts, :external_account_id, :bigint
    end

    unless index_exists?(:accounts, :external_account_id)
      add_index :accounts, :external_account_id, unique: true
    end
  end
end

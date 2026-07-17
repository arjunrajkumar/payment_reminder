class CreateNotificationSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :notification_subscriptions do |t|
      t.references :user,
        null: false,
        foreign_key: { on_delete: :cascade }
      t.string :event, null: false
      t.boolean :email, null: false, default: false
      t.timestamps
    end

    add_index :notification_subscriptions,
      %i[user_id event],
      unique: true
  end
end

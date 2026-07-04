# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_04_100000) do
  create_table "accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_accounts_on_name"
  end

  create_table "invoice_integrations", force: :cascade do |t|
    t.text "access_token"
    t.integer "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "external_account_id", null: false
    t.string "external_account_name"
    t.text "last_error"
    t.datetime "last_synced_at"
    t.string "provider", null: false
    t.json "provider_data", default: {}, null: false
    t.json "raw_token_data", default: {}, null: false
    t.text "refresh_token"
    t.json "scopes", default: [], null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider", "external_account_id"], name: "idx_on_account_id_provider_external_account_id_800201937e", unique: true
    t.index ["account_id"], name: "index_invoice_integrations_on_account_id"
    t.index ["provider", "status"], name: "index_invoice_integrations_on_provider_and_status"
  end

  create_table "users", force: :cascade do |t|
    t.integer "account_id", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "invoice_integrations", "accounts"
  add_foreign_key "users", "accounts"
end

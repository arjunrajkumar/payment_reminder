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

ActiveRecord::Schema[8.1].define(version: 2026_07_16_020000) do
  create_table "account_external_id_sequences", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "value", default: 0, null: false
    t.index ["value"], name: "index_account_external_id_sequences_on_value", unique: true
  end

  create_table "accounts", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "external_account_id"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["external_account_id"], name: "index_accounts_on_external_account_id", unique: true
    t.index ["name"], name: "index_accounts_on_name"
  end

  create_table "customer_segments", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.integer "on_time_rate"
    t.string "payer_segment", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "payer_segment"], name: "index_customer_segments_on_account_id_and_payer_segment", unique: true
    t.index ["account_id"], name: "index_customer_segments_on_account_id"
  end

  create_table "customers", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.bigint "customer_segment_id", null: false
    t.datetime "details_observed_at"
    t.string "email"
    t.string "external_id", null: false
    t.bigint "invoice_source_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "customer_segment_id"], name: "index_customers_on_account_id_and_customer_segment_id"
    t.index ["account_id", "name"], name: "index_customers_on_account_id_and_name"
    t.index ["customer_segment_id"], name: "index_customers_on_customer_segment_id"
    t.index ["invoice_source_id", "external_id"], name: "index_customers_on_invoice_source_id_and_external_id", unique: true
  end

  create_table "identities", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_identities_on_email_address", unique: true
  end

  create_table "invoice_source_webhook_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.bigint "invoice_source_id", null: false
    t.text "last_error"
    t.datetime "occurred_at"
    t.json "payload", null: false
    t.datetime "processed_at"
    t.string "provider", null: false
    t.string "provider_event_id", null: false
    t.string "resource_id"
    t.string "resource_type"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_source_id", "provider_event_id"], name: "idx_on_invoice_source_id_provider_event_id_2b2653d813", unique: true
    t.index ["invoice_source_id", "status"], name: "idx_on_invoice_source_id_status_f801f9a661"
    t.index ["invoice_source_id"], name: "index_invoice_source_webhook_events_on_invoice_source_id"
    t.index ["occurred_at"], name: "index_invoice_source_webhook_events_on_occurred_at"
  end

  create_table "invoice_sources", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "access_token"
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "external_account_id", null: false
    t.string "external_account_name"
    t.text "last_error"
    t.datetime "last_synced_at"
    t.string "provider", null: false
    t.json "provider_data", null: false
    t.json "raw_token_data", null: false
    t.text "refresh_token"
    t.json "scopes", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider"], name: "index_invoice_sources_on_account_id_and_provider", unique: true
    t.index ["account_id"], name: "index_invoice_sources_on_account_id"
    t.index ["provider", "status"], name: "index_invoice_sources_on_provider_and_status"
  end

  create_table "invoices", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.decimal "amount_due", precision: 12, scale: 2
    t.decimal "amount_paid", precision: 12, scale: 2
    t.date "completed_on"
    t.string "contact_external_id"
    t.string "contact_name"
    t.datetime "created_at", null: false
    t.string "currency"
    t.bigint "customer_id"
    t.date "due_on"
    t.string "external_id", null: false
    t.bigint "invoice_source_id", null: false
    t.string "invoice_type"
    t.date "issued_on"
    t.string "number"
    t.date "paid_on"
    t.json "provider_data", null: false
    t.string "provider_status"
    t.json "raw_data", null: false
    t.string "status", default: "unknown", null: false
    t.datetime "synced_at"
    t.decimal "total", precision: 12, scale: 2
    t.datetime "updated_at", null: false
    t.index ["account_id", "status"], name: "index_invoices_on_account_id_and_status"
    t.index ["account_id"], name: "index_invoices_on_account_id"
    t.index ["customer_id", "completed_on"], name: "index_invoices_on_customer_id_and_completed_on"
    t.index ["customer_id"], name: "index_invoices_on_customer_id"
    t.index ["due_on"], name: "index_invoices_on_due_on"
    t.index ["invoice_source_id", "external_id"], name: "index_invoices_on_invoice_source_id_and_external_id", unique: true
    t.index ["invoice_source_id"], name: "index_invoices_on_invoice_source_id"
    t.index ["paid_on"], name: "index_invoices_on_paid_on"
  end

  create_table "magic_links", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "identity_id", null: false
    t.integer "purpose", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_magic_links_on_code", unique: true
    t.index ["expires_at"], name: "index_magic_links_on_expires_at"
    t.index ["identity_id"], name: "index_magic_links_on_identity_id"
  end

  create_table "sessions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "identity_id", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["identity_id"], name: "index_sessions_on_identity_id"
  end

  create_table "users", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.bigint "identity_id"
    t.string "name", null: false
    t.string "role", default: "member", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index ["account_id", "identity_id"], name: "index_users_on_account_id_and_identity_id", unique: true
    t.index ["account_id", "role"], name: "index_users_on_account_id_and_role"
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["identity_id"], name: "index_users_on_identity_id"
  end

  add_foreign_key "customer_segments", "accounts"
  add_foreign_key "customers", "accounts"
  add_foreign_key "customers", "customer_segments"
  add_foreign_key "customers", "invoice_sources"
  add_foreign_key "invoice_source_webhook_events", "invoice_sources"
  add_foreign_key "invoice_sources", "accounts"
  add_foreign_key "invoices", "accounts"
  add_foreign_key "invoices", "customers"
  add_foreign_key "invoices", "invoice_sources"
  add_foreign_key "magic_links", "identities"
  add_foreign_key "sessions", "identities"
  add_foreign_key "users", "accounts"
  add_foreign_key "users", "identities"
end

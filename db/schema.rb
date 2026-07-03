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

ActiveRecord::Schema[8.1].define(version: 2026_07_03_000100) do
  create_table "xero_connections", force: :cascade do |t|
    t.text "access_token", null: false
    t.json "connections", default: [], null: false
    t.datetime "created_at", null: false
    t.string "email"
    t.datetime "expires_at", null: false
    t.text "id_token"
    t.json "raw_token_set", default: {}, null: false
    t.json "raw_userinfo", default: {}, null: false
    t.text "refresh_token", null: false
    t.json "scopes", default: [], null: false
    t.string "tenant_id"
    t.string "tenant_name"
    t.string "token_type", null: false
    t.datetime "updated_at", null: false
    t.string "xero_user_id"
    t.index ["tenant_id"], name: "index_xero_connections_on_tenant_id"
    t.index ["xero_user_id"], name: "index_xero_connections_on_xero_user_id"
  end
end

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

ActiveRecord::Schema[8.1].define(version: 2026_07_24_150000) do
  create_table "account_external_id_sequences", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "value", default: 0, null: false
    t.index ["value"], name: "index_account_external_id_sequences_on_value", unique: true
  end

  create_table "accounts", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.boolean "automatic_invoice_reminders_enabled", default: false, null: false
    t.datetime "conversation_ai_enabled_at"
    t.string "conversation_ai_mode", default: "off", null: false
    t.string "conversation_ai_provider"
    t.datetime "created_at", null: false
    t.bigint "external_account_id", null: false
    t.string "invoice_reminder_from_email"
    t.string "invoice_reminder_from_name"
    t.string "name", null: false
    t.string "time_zone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.index ["external_account_id"], name: "index_accounts_on_external_account_id", unique: true
    t.index ["name"], name: "index_accounts_on_name"
    t.check_constraint "`conversation_ai_mode` in (_utf8mb4'off',_utf8mb4'shadow')", name: "accounts_conversation_ai_mode"
  end

  create_table "collection_holds", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "conversation_action_id"
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.bigint "customer_id"
    t.json "customer_snapshot", null: false
    t.string "idempotency_key", null: false
    t.json "in_flight_delivery_message_ids", null: false
    t.bigint "invoice_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.text "note"
    t.datetime "placed_at", null: false
    t.string "placed_by_kind", null: false
    t.bigint "placed_by_user_id"
    t.string "reason", null: false
    t.string "release_idempotency_key"
    t.text "release_note"
    t.datetime "released_at"
    t.bigint "released_by_user_id"
    t.bigint "source_message_id"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "idempotency_key"], name: "index_collection_holds_on_account_and_idempotency", unique: true
    t.index ["account_id"], name: "index_collection_holds_on_account_id"
    t.index ["conversation_action_id"], name: "index_collection_holds_on_conversation_action_id"
    t.index ["conversation_id", "status"], name: "index_collection_holds_on_conversation_id_and_status"
    t.index ["conversation_id"], name: "index_collection_holds_on_conversation_id"
    t.index ["customer_id"], name: "index_collection_holds_on_customer_id"
    t.index ["invoice_id", "status"], name: "index_collection_holds_on_invoice_id_and_status"
    t.index ["invoice_id"], name: "index_collection_holds_on_invoice_id"
    t.index ["placed_by_user_id"], name: "index_collection_holds_on_placed_by_user_id"
    t.index ["released_by_user_id"], name: "index_collection_holds_on_released_by_user_id"
    t.index ["source_message_id"], name: "index_collection_holds_on_source_message_id"
    t.check_constraint "((`status` = _utf8mb4'active') and (`released_at` is null) and (`release_idempotency_key` is null)) or ((`status` = _utf8mb4'released') and (`released_at` is not null) and (`release_idempotency_key` is not null))", name: "collection_holds_release_state"
    t.check_constraint "`reason` in (_utf8mb4'manual',_utf8mb4'dispute',_utf8mb4'other')", name: "collection_holds_reason"
    t.check_constraint "`status` in (_utf8mb4'active',_utf8mb4'released')", name: "collection_holds_status"
  end

  create_table "conversation_action_executions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.integer "acknowledged_attention_version", default: 0, null: false
    t.bigint "approved_by_user_id"
    t.json "approver_snapshot", null: false
    t.integer "attempts", default: 0, null: false
    t.boolean "attention_required", default: false, null: false
    t.integer "attention_version", default: 0, null: false
    t.integer "claim_generation", default: 0, null: false
    t.string "claim_token", collation: "utf8mb4_0900_bin"
    t.datetime "claimed_at"
    t.bigint "collection_hold_id"
    t.bigint "conversation_action_id", null: false
    t.bigint "conversation_action_revision_id", null: false
    t.datetime "created_at", null: false
    t.bigint "customer_email_address_id"
    t.bigint "delivery_escalation_id"
    t.datetime "delivery_finalized_at"
    t.datetime "effect_applied_at"
    t.datetime "effect_completed_at"
    t.bigint "effect_escalation_id"
    t.string "failure_category"
    t.text "failure_reason"
    t.string "finalization_status", default: "not_required", null: false
    t.datetime "finished_at"
    t.string "last_scheduling_error", limit: 2000
    t.integer "lock_version", default: 0, null: false
    t.datetime "next_retry_at"
    t.datetime "next_scheduling_at"
    t.bigint "payment_promise_id"
    t.string "phase", default: "effect", null: false
    t.json "reply_snapshot", null: false
    t.string "result_code"
    t.json "result_metadata", null: false
    t.datetime "schedule_consumed_at"
    t.datetime "scheduled_at"
    t.integer "scheduling_attempts", default: 0, null: false
    t.datetime "scheduling_claimed_at"
    t.integer "scheduling_generation", default: 0, null: false
    t.string "scheduling_status", default: "reserved", null: false
    t.string "scheduling_token", collation: "utf8mb4_0900_bin"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conversation_action_executions_on_account_id"
    t.index ["approved_by_user_id"], name: "index_conversation_action_executions_on_approved_by_user_id"
    t.index ["collection_hold_id"], name: "index_conversation_action_executions_on_collection_hold_id"
    t.index ["conversation_action_id"], name: "index_conversation_action_executions_on_conversation_action_id", unique: true
    t.index ["conversation_action_revision_id"], name: "idx_on_conversation_action_revision_id_5570f7b3cf", unique: true
    t.index ["customer_email_address_id"], name: "idx_on_customer_email_address_id_fee00149cd"
    t.index ["delivery_escalation_id"], name: "index_conversation_action_executions_on_delivery_escalation_id"
    t.index ["effect_escalation_id"], name: "index_conversation_action_executions_on_effect_escalation_id"
    t.index ["finalization_status", "status", "id"], name: "index_action_executions_on_finalization"
    t.index ["payment_promise_id"], name: "index_conversation_action_executions_on_payment_promise_id"
    t.index ["scheduling_status", "next_scheduling_at", "id"], name: "index_action_executions_on_due_scheduling"
    t.index ["scheduling_status", "scheduled_at", "schedule_consumed_at", "id"], name: "index_action_executions_on_lost_scheduling"
    t.index ["scheduling_status", "scheduling_claimed_at", "id"], name: "index_action_executions_on_stale_scheduling"
    t.index ["status", "claimed_at", "id"], name: "index_action_executions_on_stale_claims"
    t.index ["status", "phase", "next_retry_at", "id"], name: "index_action_executions_on_pending_phase"
    t.check_constraint "((`finalization_status` = _utf8mb4'completed') and (`delivery_finalized_at` is not null)) or ((`finalization_status` <> _utf8mb4'completed') and (`delivery_finalized_at` is null))", name: "conversation_action_executions_finalization"
    t.check_constraint "((`scheduling_status` = _utf8mb4'claimed') and (`scheduling_token` is not null) and (`scheduling_claimed_at` is not null)) or ((`scheduling_status` <> _utf8mb4'claimed') and (`scheduling_token` is null) and (`scheduling_claimed_at` is null))", name: "conversation_action_executions_schedule_claim"
    t.check_constraint "((`status` = _utf8mb4'running') and (`claim_token` is not null) and (`claimed_at` is not null)) or ((`status` <> _utf8mb4'running') and (`claim_token` is null) and (`claimed_at` is null))", name: "conversation_action_executions_claim"
    t.check_constraint "((`status` in (_utf8mb4'succeeded',_utf8mb4'failed',_utf8mb4'uncertain',_utf8mb4'canceled')) and (`finished_at` is not null) and (`phase` = _utf8mb4'finalized')) or ((`status` not in (_utf8mb4'succeeded',_utf8mb4'failed',_utf8mb4'uncertain',_utf8mb4'canceled')) and (`finished_at` is null) and (`phase` <> _utf8mb4'finalized'))", name: "conversation_action_executions_terminal"
    t.check_constraint "(`acknowledged_attention_version` >= 0) and (`acknowledged_attention_version` <= `attention_version`)", name: "conversation_action_executions_attention_versions"
    t.check_constraint "(`attempts` >= 0) and (`attempts` <= 5) and (`claim_generation` >= 0)", name: "conversation_action_executions_attempts"
    t.check_constraint "(`scheduling_attempts` >= 0) and (`scheduling_attempts` <= 5) and (`scheduling_generation` >= 0)", name: "conversation_action_executions_scheduling_attempts"
    t.check_constraint "`finalization_status` in (_utf8mb4'not_required',_utf8mb4'pending',_utf8mb4'completed')", name: "conversation_action_executions_finalization_status"
    t.check_constraint "`phase` in (_utf8mb4'effect',_utf8mb4'reply_reservation',_utf8mb4'delivery',_utf8mb4'finalized')", name: "conversation_action_executions_phase"
    t.check_constraint "`scheduling_status` in (_utf8mb4'reserved',_utf8mb4'claimed',_utf8mb4'enqueued',_utf8mb4'consumed',_utf8mb4'exhausted',_utf8mb4'canceled')", name: "conversation_action_executions_scheduling_status"
    t.check_constraint "`status` in (_utf8mb4'pending',_utf8mb4'running',_utf8mb4'awaiting_delivery',_utf8mb4'succeeded',_utf8mb4'failed',_utf8mb4'uncertain',_utf8mb4'canceled')", name: "conversation_action_executions_status"
  end

  create_table "conversation_action_revisions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.json "arguments", null: false
    t.string "author_kind", null: false
    t.bigint "author_user_id"
    t.bigint "conversation_action_id", null: false
    t.datetime "created_at", null: false
    t.bigint "customer_id"
    t.string "idempotency_key", null: false
    t.bigint "invoice_id"
    t.json "proposed_reply", null: false
    t.text "rationale"
    t.integer "revision_number", null: false
    t.datetime "updated_at", null: false
    t.text "user_facing_summary", null: false
    t.index ["author_user_id"], name: "index_conversation_action_revisions_on_author_user_id"
    t.index ["conversation_action_id", "idempotency_key"], name: "index_action_revisions_on_action_and_idempotency", unique: true
    t.index ["conversation_action_id", "revision_number"], name: "index_action_revisions_on_action_and_number", unique: true
    t.index ["conversation_action_id"], name: "index_conversation_action_revisions_on_conversation_action_id"
    t.index ["customer_id"], name: "index_conversation_action_revisions_on_customer_id"
    t.index ["invoice_id"], name: "index_conversation_action_revisions_on_invoice_id"
    t.check_constraint "`author_kind` in (_utf8mb4'user',_utf8mb4'system',_utf8mb4'ai')", name: "conversation_action_revisions_author_kind"
    t.check_constraint "`revision_number` > 0", name: "conversation_action_revisions_number_positive"
  end

  create_table "conversation_actions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "action_type", null: false
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id"
    t.datetime "decided_at"
    t.bigint "decided_by_user_id"
    t.bigint "decided_revision_id"
    t.json "decision_actor_snapshot"
    t.string "decision_idempotency_key"
    t.text "decision_note"
    t.string "idempotency_key", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "origin_kind", null: false
    t.bigint "source_message_id"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "idempotency_key"], name: "index_conversation_actions_on_account_and_idempotency", unique: true
    t.index ["account_id"], name: "index_conversation_actions_on_account_id"
    t.index ["conversation_id", "status"], name: "index_conversation_actions_on_conversation_id_and_status"
    t.index ["conversation_id"], name: "index_conversation_actions_on_conversation_id"
    t.index ["created_by_user_id"], name: "index_conversation_actions_on_created_by_user_id"
    t.index ["decided_by_user_id"], name: "index_conversation_actions_on_decided_by_user_id"
    t.index ["decided_revision_id"], name: "index_conversation_actions_on_decided_revision_id"
    t.index ["source_message_id"], name: "index_conversation_actions_on_source_message_id"
    t.check_constraint "((`status` = _utf8mb4'pending_approval') and (`decided_at` is null) and (`decision_idempotency_key` is null)) or ((`status` in (_utf8mb4'approved',_utf8mb4'rejected')) and (`decided_at` is not null) and (`decision_idempotency_key` is not null))", name: "conversation_actions_decision_state"
    t.check_constraint "`origin_kind` in (_utf8mb4'user',_utf8mb4'system',_utf8mb4'ai')", name: "conversation_actions_origin_kind"
    t.check_constraint "`status` in (_utf8mb4'pending_approval',_utf8mb4'approved',_utf8mb4'rejected')", name: "conversation_actions_status"
  end

  create_table "conversation_ai_evaluations", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.json "actor_snapshot", null: false
    t.bigint "actor_user_id"
    t.bigint "conversation_ai_plan_id", null: false
    t.bigint "conversation_interpretation_id", null: false
    t.string "corrected_action_type"
    t.json "corrected_arguments", null: false
    t.string "corrected_message_kind"
    t.datetime "created_at", null: false
    t.string "idempotency_key", null: false, collation: "utf8mb4_0900_bin"
    t.text "note"
    t.bigint "supersedes_evaluation_id"
    t.datetime "updated_at", null: false
    t.string "verdict", null: false
    t.index ["account_id", "idempotency_key"], name: "index_ai_evaluations_on_account_idempotency", unique: true
    t.index ["account_id"], name: "index_conversation_ai_evaluations_on_account_id"
    t.index ["actor_user_id"], name: "index_conversation_ai_evaluations_on_actor_user_id"
    t.index ["conversation_ai_plan_id"], name: "index_conversation_ai_evaluations_on_conversation_ai_plan_id"
    t.index ["conversation_interpretation_id", "created_at"], name: "index_ai_evaluations_on_interpretation_history"
    t.index ["conversation_interpretation_id"], name: "idx_on_conversation_interpretation_id_d080086c01"
    t.index ["supersedes_evaluation_id"], name: "index_conversation_ai_evaluations_on_supersedes_evaluation_id"
    t.check_constraint "`verdict` in (_utf8mb4'correct',_utf8mb4'incorrect',_utf8mb4'unsure')", name: "conversation_ai_evaluations_verdict"
  end

  create_table "conversation_ai_invocations", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "api_version", null: false
    t.string "application_request_id", null: false, collation: "utf8mb4_0900_bin"
    t.integer "attempt_number", null: false
    t.string "attempt_token", null: false, collation: "utf8mb4_0900_bin"
    t.integer "cached_input_tokens"
    t.integer "claim_generation", null: false
    t.bigint "conversation_interpretation_id", null: false
    t.datetime "created_at", null: false
    t.string "endpoint", null: false
    t.string "failure_category"
    t.string "failure_class"
    t.string "failure_message", limit: 2000
    t.datetime "finished_at"
    t.integer "input_tokens"
    t.integer "latency_ms"
    t.integer "output_tokens"
    t.boolean "possible_duplicate_cost", default: false, null: false
    t.string "provider", null: false
    t.string "provider_adapter_version", null: false
    t.json "provider_metadata", null: false
    t.string "provider_request_id"
    t.string "requested_model", null: false
    t.integer "response_status"
    t.integer "retry_after_seconds"
    t.string "returned_model"
    t.json "sanitized_request", null: false
    t.json "sanitized_response", null: false
    t.datetime "started_at", null: false
    t.string "status", default: "started", null: false
    t.integer "total_tokens"
    t.datetime "updated_at", null: false
    t.index ["account_id", "status", "created_at"], name: "index_ai_invocations_on_account_status"
    t.index ["account_id"], name: "index_conversation_ai_invocations_on_account_id"
    t.index ["application_request_id"], name: "index_ai_invocations_on_application_request", unique: true
    t.index ["conversation_interpretation_id", "attempt_number"], name: "index_ai_invocations_on_interpretation_attempt", unique: true
    t.index ["conversation_interpretation_id"], name: "idx_on_conversation_interpretation_id_4ccc2211f7"
    t.check_constraint "((`status` = _utf8mb4'started') and (`finished_at` is null)) or ((`status` <> _utf8mb4'started') and (`finished_at` is not null))", name: "conversation_ai_invocations_finished"
    t.check_constraint "(`attempt_number` > 0) and (`attempt_number` <= 5) and (`claim_generation` >= 0)", name: "conversation_ai_invocations_attempt"
    t.check_constraint "`status` in (_utf8mb4'started',_utf8mb4'succeeded',_utf8mb4'failed',_utf8mb4'uncertain',_utf8mb4'superseded')", name: "conversation_ai_invocations_status"
  end

  create_table "conversation_ai_plans", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.json "arguments", null: false
    t.string "catalog_version", null: false
    t.integer "confidence_bps"
    t.bigint "conversation_interpretation_id", null: false
    t.datetime "created_at", null: false
    t.string "decision", null: false
    t.json "planner_reason_codes", null: false
    t.string "planner_version", null: false
    t.string "proposed_action_type"
    t.json "proposed_reply", null: false
    t.string "status", default: "current", null: false
    t.datetime "superseded_at"
    t.datetime "updated_at", null: false
    t.string "user_facing_summary", limit: 1000, null: false
    t.index ["account_id", "decision", "created_at"], name: "index_ai_plans_on_account_decision"
    t.index ["account_id"], name: "index_conversation_ai_plans_on_account_id"
    t.index ["conversation_interpretation_id"], name: "index_conversation_ai_plans_on_conversation_interpretation_id", unique: true
    t.check_constraint "((`decision` = _utf8mb4'propose_action') and (`proposed_action_type` is not null)) or ((`decision` <> _utf8mb4'propose_action') and (`proposed_action_type` is null))", name: "conversation_ai_plans_action"
    t.check_constraint "((`status` = _utf8mb4'current') and (`superseded_at` is null)) or ((`status` = _utf8mb4'superseded') and (`superseded_at` is not null))", name: "conversation_ai_plans_lifecycle"
    t.check_constraint "(`confidence_bps` is null) or ((`confidence_bps` >= 0) and (`confidence_bps` <= 10000))", name: "conversation_ai_plans_confidence"
    t.check_constraint "`decision` in (_utf8mb4'propose_action',_utf8mb4'human_review',_utf8mb4'no_action')", name: "conversation_ai_plans_decision"
    t.check_constraint "`status` in (_utf8mb4'current',_utf8mb4'superseded')", name: "conversation_ai_plans_status"
  end

  create_table "conversation_escalations", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "category", null: false
    t.bigint "collection_hold_id"
    t.bigint "conversation_action_id"
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.bigint "customer_id"
    t.text "details"
    t.string "idempotency_key", null: false
    t.bigint "invoice_id"
    t.datetime "last_opened_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "opened_at", null: false
    t.string "opened_by_kind", null: false
    t.bigint "opened_by_user_id"
    t.string "priority", null: false
    t.text "resolution_note"
    t.datetime "resolved_at"
    t.bigint "resolved_by_user_id"
    t.bigint "source_message_id"
    t.string "status", null: false
    t.text "summary", null: false
    t.string "transition_idempotency_key"
    t.datetime "updated_at", null: false
    t.index ["account_id", "idempotency_key"], name: "index_escalations_on_account_and_idempotency", unique: true
    t.index ["account_id"], name: "index_conversation_escalations_on_account_id"
    t.index ["collection_hold_id"], name: "index_conversation_escalations_on_collection_hold_id"
    t.index ["conversation_action_id"], name: "index_conversation_escalations_on_conversation_action_id"
    t.index ["conversation_id", "status"], name: "index_conversation_escalations_on_conversation_id_and_status"
    t.index ["conversation_id"], name: "index_conversation_escalations_on_conversation_id"
    t.index ["customer_id"], name: "index_conversation_escalations_on_customer_id"
    t.index ["invoice_id", "status"], name: "index_conversation_escalations_on_invoice_id_and_status"
    t.index ["invoice_id"], name: "index_conversation_escalations_on_invoice_id"
    t.index ["opened_by_user_id"], name: "index_conversation_escalations_on_opened_by_user_id"
    t.index ["resolved_by_user_id"], name: "index_conversation_escalations_on_resolved_by_user_id"
    t.index ["source_message_id"], name: "index_conversation_escalations_on_source_message_id"
    t.check_constraint "((`status` = _utf8mb4'open') and (`resolved_at` is null) and (`resolution_note` is null)) or ((`status` = _utf8mb4'resolved') and (`resolved_at` is not null))", name: "conversation_escalations_resolution_state"
    t.check_constraint "`category` in (_utf8mb4'dispute',_utf8mb4'low_confidence',_utf8mb4'ambiguous',_utf8mb4'delivery_failure',_utf8mb4'connection_failure',_utf8mb4'other')", name: "conversation_escalations_category"
    t.check_constraint "`priority` in (_utf8mb4'normal',_utf8mb4'high',_utf8mb4'urgent')", name: "conversation_escalations_priority"
    t.check_constraint "`status` in (_utf8mb4'open',_utf8mb4'resolved')", name: "conversation_escalations_status"
  end

  create_table "conversation_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "actor_kind", null: false
    t.bigint "actor_user_id"
    t.string "ai_event_key", collation: "utf8mb4_0900_bin"
    t.bigint "conversation_id", null: false
    t.bigint "conversation_message_id"
    t.datetime "created_at", null: false
    t.string "execution_event_key", collation: "utf8mb4_0900_bin"
    t.string "kind", null: false
    t.json "metadata", null: false
    t.index ["account_id", "kind", "created_at"], name: "index_conversation_events_on_account_kind_created_at"
    t.index ["actor_user_id"], name: "index_conversation_events_on_actor_user_id"
    t.index ["ai_event_key"], name: "index_conversation_events_on_ai_event_key", unique: true
    t.index ["conversation_id", "created_at", "id"], name: "index_conversation_events_on_conversation_created_at_id"
    t.index ["conversation_message_id", "kind"], name: "index_conversation_events_on_message_and_kind", unique: true
    t.index ["conversation_message_id"], name: "index_conversation_events_on_conversation_message_id"
    t.index ["execution_event_key"], name: "index_conversation_events_on_execution_event_key", unique: true
  end

  create_table "conversation_interpretations", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "accepted_model"
    t.bigint "account_id", null: false
    t.string "analysis_key", null: false, collation: "utf8mb4_0900_bin"
    t.text "authored_content_snapshot"
    t.json "authored_content_warnings", null: false
    t.datetime "canceled_at"
    t.string "catalog_version", null: false
    t.integer "claim_generation", default: 0, null: false
    t.string "claim_token", collation: "utf8mb4_0900_bin"
    t.datetime "claimed_at"
    t.datetime "completed_at"
    t.text "concise_rationale"
    t.json "context_snapshot", null: false
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.bigint "customer_ai_guidance_revision_id"
    t.bigint "customer_id"
    t.string "failure_category"
    t.text "failure_reason"
    t.datetime "finalized_at"
    t.string "input_digest", collation: "utf8mb4_0900_bin"
    t.bigint "invoice_id"
    t.string "language"
    t.string "last_scheduling_error", limit: 2000
    t.integer "lock_version", default: 0, null: false
    t.string "message_kind"
    t.datetime "next_retry_at"
    t.datetime "next_scheduling_at"
    t.integer "overall_confidence_bps"
    t.string "planner_version", null: false
    t.string "provider", null: false
    t.string "provider_adapter_version", null: false
    t.integer "provider_attempts", default: 0, null: false
    t.json "reason_codes", null: false
    t.string "requested_mode", default: "shadow", null: false
    t.string "requested_model", null: false
    t.boolean "requires_human"
    t.string "result_schema_version", null: false
    t.integer "scheduling_attempts", default: 0, null: false
    t.datetime "scheduling_claimed_at"
    t.datetime "scheduling_consumed_at"
    t.datetime "scheduling_enqueued_at"
    t.integer "scheduling_generation", default: 0, null: false
    t.string "scheduling_status", default: "reserved", null: false
    t.string "scheduling_token", collation: "utf8mb4_0900_bin"
    t.string "semantic_prompt_version", null: false
    t.json "source_identity_snapshot", null: false
    t.bigint "source_message_id", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.json "structured_result", null: false
    t.string "summary", limit: 1000
    t.datetime "superseded_at"
    t.bigint "supersedes_interpretation_id"
    t.datetime "updated_at", null: false
    t.index ["account_id", "analysis_key"], name: "index_interpretations_on_account_analysis_key", unique: true
    t.index ["account_id", "conversation_id", "status", "created_at"], name: "index_interpretations_on_conversation_status"
    t.index ["account_id", "provider", "requested_model", "semantic_prompt_version"], name: "index_interpretations_on_report_versions"
    t.index ["account_id", "source_message_id", "created_at"], name: "index_interpretations_on_source_history"
    t.index ["account_id", "status", "completed_at", "id"], name: "index_interpretations_on_account_status"
    t.index ["account_id"], name: "index_conversation_interpretations_on_account_id"
    t.index ["conversation_id"], name: "index_conversation_interpretations_on_conversation_id"
    t.index ["customer_ai_guidance_revision_id"], name: "idx_on_customer_ai_guidance_revision_id_7a24722c4e"
    t.index ["customer_id"], name: "index_conversation_interpretations_on_customer_id"
    t.index ["invoice_id"], name: "index_conversation_interpretations_on_invoice_id"
    t.index ["scheduling_status", "next_scheduling_at", "id"], name: "index_interpretations_on_due_scheduling"
    t.index ["scheduling_status", "scheduling_claimed_at", "id"], name: "index_interpretations_on_stale_scheduling"
    t.index ["scheduling_status", "scheduling_enqueued_at", "scheduling_consumed_at", "id"], name: "index_interpretations_on_lost_scheduling"
    t.index ["source_message_id"], name: "index_conversation_interpretations_on_source_message_id"
    t.index ["status", "claimed_at", "id"], name: "index_interpretations_on_stale_claims"
    t.index ["status", "finalized_at", "id"], name: "index_interpretations_on_finalization"
    t.index ["status", "next_retry_at", "id"], name: "index_interpretations_on_due_retry"
    t.index ["supersedes_interpretation_id"], name: "idx_on_supersedes_interpretation_id_cf1aa8fcd8"
    t.check_constraint "((`scheduling_status` = _utf8mb4'claimed') and (`scheduling_token` is not null) and (`scheduling_claimed_at` is not null)) or ((`scheduling_status` <> _utf8mb4'claimed') and (`scheduling_token` is null) and (`scheduling_claimed_at` is null))", name: "conversation_interpretations_schedule_claim"
    t.check_constraint "((`status` = _utf8mb4'running') and (`claim_token` is not null) and (`claimed_at` is not null)) or ((`status` <> _utf8mb4'running') and (`claim_token` is null) and (`claimed_at` is null))", name: "conversation_interpretations_claim"
    t.check_constraint "((`status` in (_utf8mb4'succeeded',_utf8mb4'failed',_utf8mb4'skipped')) and (`completed_at` is not null)) or ((`status` = _utf8mb4'canceled') and (`canceled_at` is not null)) or ((`status` = _utf8mb4'superseded') and (`superseded_at` is not null)) or ((`status` in (_utf8mb4'pending',_utf8mb4'running')) and (`completed_at` is null) and (`canceled_at` is null) and (`superseded_at` is null))", name: "conversation_interpretations_terminal"
    t.check_constraint "(`overall_confidence_bps` is null) or ((`overall_confidence_bps` >= 0) and (`overall_confidence_bps` <= 10000))", name: "conversation_interpretations_confidence"
    t.check_constraint "(`scheduling_attempts` >= 0) and (`scheduling_attempts` <= 5) and (`scheduling_generation` >= 0) and (`provider_attempts` >= 0) and (`provider_attempts` <= 5) and (`claim_generation` >= 0)", name: "conversation_interpretations_attempts"
    t.check_constraint "`requested_mode` = _utf8mb4'shadow'", name: "conversation_interpretations_mode"
    t.check_constraint "`scheduling_status` in (_utf8mb4'reserved',_utf8mb4'claimed',_utf8mb4'enqueued',_utf8mb4'consumed',_utf8mb4'exhausted',_utf8mb4'canceled')", name: "conversation_interpretations_scheduling_status"
    t.check_constraint "`status` in (_utf8mb4'pending',_utf8mb4'running',_utf8mb4'succeeded',_utf8mb4'failed',_utf8mb4'canceled',_utf8mb4'superseded',_utf8mb4'skipped')", name: "conversation_interpretations_status"
  end

  create_table "conversation_messages", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.json "actor_snapshot"
    t.bigint "actor_user_id"
    t.boolean "automatic", default: false, null: false
    t.json "bcc_addresses", null: false
    t.text "body"
    t.json "cc_addresses", null: false
    t.bigint "conversation_action_execution_id"
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "delivery_attempted_at"
    t.string "delivery_job_id", collation: "utf8mb4_0900_bin"
    t.boolean "delivery_uncertain", default: false, null: false
    t.string "direction", null: false
    t.integer "email_connection_generation"
    t.bigint "email_connection_id"
    t.text "failure_reason"
    t.string "from_address"
    t.string "idempotency_key", collation: "utf8mb4_0900_bin"
    t.json "in_reply_to_message_ids", null: false
    t.text "internet_message_id"
    t.string "internet_message_id_digest", limit: 64, collation: "utf8mb4_0900_bin"
    t.bigint "invoice_id"
    t.string "kind", null: false
    t.string "last_reply_scheduling_error", limit: 2000
    t.virtual "manual_reminder_delivery_job_id", type: :string, collation: "utf8mb4_0900_bin", as: "if((`kind` = _utf8mb4'manual_reminder'),`delivery_job_id`,NULL)", stored: true
    t.string "matching_method", default: "none", null: false
    t.string "matching_status", default: "matched", null: false
    t.datetime "next_reply_scheduling_at"
    t.string "provider_account_id", collation: "utf8mb4_0900_bin"
    t.datetime "provider_delivery_started_at"
    t.string "provider_message_id", collation: "utf8mb4_0900_bin"
    t.json "provider_metadata", null: false
    t.string "provider_thread_id", collation: "utf8mb4_0900_bin"
    t.datetime "received_at"
    t.json "reference_message_ids", null: false
    t.datetime "reply_schedule_consumed_at"
    t.datetime "reply_scheduled_at"
    t.integer "reply_scheduling_attempts", default: 0, null: false
    t.datetime "reply_scheduling_claimed_at"
    t.integer "reply_scheduling_generation", default: 0, null: false
    t.string "reply_scheduling_status"
    t.string "reply_scheduling_token", collation: "utf8mb4_0900_bin"
    t.json "reply_to_addresses", null: false
    t.bigint "reply_to_message_id"
    t.string "requested_provider_account_id", collation: "utf8mb4_0900_bin"
    t.string "requested_provider_thread_id", collation: "utf8mb4_0900_bin"
    t.string "review_outcome"
    t.json "review_reasons", null: false
    t.boolean "review_required", default: false, null: false
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_user_id"
    t.datetime "sent_at"
    t.string "status", default: "pending", null: false
    t.text "subject"
    t.json "to_addresses", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "idempotency_key"], name: "index_conversation_messages_on_account_idempotency", unique: true
    t.index ["account_id", "provider_account_id", "internet_message_id_digest"], name: "index_conversation_messages_on_account_rfc_message"
    t.index ["account_id", "provider_account_id", "provider_message_id"], name: "index_conversation_messages_on_provider_message", unique: true
    t.index ["account_id", "provider_account_id", "provider_thread_id"], name: "index_conversation_messages_on_provider_thread"
    t.index ["account_id", "requested_provider_account_id", "requested_provider_thread_id", "status"], name: "index_conversation_messages_on_requested_thread"
    t.index ["account_id", "review_required", "reviewed_at", "received_at"], name: "index_conversation_messages_for_review"
    t.index ["account_id"], name: "index_conversation_messages_on_account_id"
    t.index ["actor_user_id"], name: "index_conversation_messages_on_actor_user_id"
    t.index ["conversation_action_execution_id"], name: "index_action_reply_on_execution", unique: true
    t.index ["conversation_id", "created_at", "id"], name: "index_conversation_messages_on_conversation_created_at_id"
    t.index ["delivery_job_id"], name: "index_conversation_messages_on_delivery_job_id"
    t.index ["email_connection_id"], name: "index_conversation_messages_on_email_connection_id"
    t.index ["invoice_id", "direction", "status", "sent_at"], name: "index_conversation_messages_on_outbound_delivery"
    t.index ["invoice_id"], name: "index_conversation_messages_on_invoice_id"
    t.index ["kind", "status", "conversation_action_execution_id", "id"], name: "index_action_replies_on_finalization"
    t.index ["manual_reminder_delivery_job_id"], name: "index_manual_reminders_on_delivery_job_id", unique: true
    t.index ["reply_scheduling_status", "next_reply_scheduling_at", "id"], name: "index_action_replies_on_due_scheduling"
    t.index ["reply_scheduling_status", "reply_scheduled_at", "reply_schedule_consumed_at", "id"], name: "index_action_replies_on_lost_scheduling"
    t.index ["reply_scheduling_status", "reply_scheduling_claimed_at", "id"], name: "index_action_replies_on_stale_scheduling"
    t.index ["reply_to_message_id"], name: "index_conversation_messages_on_reply_to_message_id"
    t.index ["reviewed_by_user_id"], name: "index_conversation_messages_on_reviewed_by_user_id"
    t.index ["status", "delivery_attempted_at"], name: "index_conversation_messages_on_pending_delivery_age"
    t.index ["status", "provider_delivery_started_at"], name: "index_conversation_messages_on_provider_delivery_claim"
    t.check_constraint "((`reply_scheduling_status` = _utf8mb4'claimed') and (`reply_scheduling_token` is not null) and (`reply_scheduling_claimed_at` is not null)) or ((`reply_scheduling_status` <> _utf8mb4'claimed') and (`reply_scheduling_token` is null) and (`reply_scheduling_claimed_at` is null)) or (`reply_scheduling_status` is null)", name: "conversation_messages_action_reply_claim"
    t.check_constraint "(`reply_scheduling_attempts` >= 0) and (`reply_scheduling_attempts` <= 5) and (`reply_scheduling_generation` >= 0)", name: "conversation_messages_action_reply_attempts"
    t.check_constraint "(`reply_scheduling_status` is null) or (`reply_scheduling_status` in (_utf8mb4'reserved',_utf8mb4'claimed',_utf8mb4'enqueued',_utf8mb4'consumed',_utf8mb4'exhausted',_utf8mb4'canceled'))", name: "conversation_messages_action_reply_scheduling"
  end

  create_table "conversations", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "attention_required_at"
    t.bigint "canonical_conversation_id"
    t.datetime "created_at", null: false
    t.bigint "customer_id"
    t.bigint "invoice_id"
    t.datetime "resolved_at"
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "attention_required_at", "id"], name: "index_conversations_for_attention"
    t.index ["account_id", "canonical_conversation_id"], name: "index_conversations_on_account_and_canonical"
    t.index ["account_id", "status", "updated_at"], name: "index_conversations_on_account_status_updated_at"
    t.index ["canonical_conversation_id"], name: "fk_rails_d4cd3b561f"
    t.index ["customer_id", "status", "updated_at"], name: "index_conversations_on_customer_status_updated_at"
    t.index ["invoice_id"], name: "index_conversations_on_invoice_id", unique: true
    t.check_constraint "((`status` = _utf8mb4'open') and (`resolved_at` is null)) or ((`status` = _utf8mb4'resolved') and (`resolved_at` is not null))", name: "conversations_status_and_resolved_at_consistent"
  end

  create_table "customer_ai_guidance_revisions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "activated_at"
    t.string "author_kind", null: false
    t.json "author_snapshot", null: false
    t.bigint "author_user_id"
    t.datetime "created_at", null: false
    t.bigint "customer_ai_profile_id", null: false
    t.json "evidence_snapshot", null: false
    t.string "idempotency_key", null: false, collation: "utf8mb4_0900_bin"
    t.datetime "rejected_at"
    t.integer "revision_number", null: false
    t.bigint "source_signal_id"
    t.string "status", null: false
    t.json "structured_guidance", null: false
    t.string "summary", limit: 500, null: false
    t.datetime "superseded_at"
    t.datetime "updated_at", null: false
    t.index ["account_id", "status", "created_at"], name: "index_customer_ai_guidance_on_account_status"
    t.index ["account_id"], name: "index_customer_ai_guidance_revisions_on_account_id"
    t.index ["author_user_id"], name: "index_customer_ai_guidance_revisions_on_author_user_id"
    t.index ["customer_ai_profile_id", "idempotency_key"], name: "index_customer_ai_guidance_on_profile_idempotency", unique: true
    t.index ["customer_ai_profile_id", "revision_number"], name: "index_customer_ai_guidance_on_profile_revision", unique: true
    t.index ["customer_ai_profile_id"], name: "index_customer_ai_guidance_revisions_on_customer_ai_profile_id"
    t.index ["source_signal_id"], name: "index_customer_ai_guidance_revisions_on_source_signal_id"
    t.check_constraint "((`status` = _utf8mb4'active') and (`activated_at` is not null) and (`rejected_at` is null) and (`superseded_at` is null)) or ((`status` = _utf8mb4'rejected') and (`rejected_at` is not null) and (`activated_at` is null) and (`superseded_at` is null)) or ((`status` = _utf8mb4'superseded') and (`superseded_at` is not null) and (`activated_at` is not null) and (`rejected_at` is null)) or ((`status` = _utf8mb4'proposed') and (`activated_at` is null) and (`rejected_at` is null) and (`superseded_at` is null))", name: "customer_ai_guidance_revisions_lifecycle"
    t.check_constraint "`author_kind` in (_utf8mb4'user',_utf8mb4'ai')", name: "customer_ai_guidance_revisions_author_kind"
    t.check_constraint "`revision_number` > 0", name: "customer_ai_guidance_revisions_number"
    t.check_constraint "`status` in (_utf8mb4'proposed',_utf8mb4'active',_utf8mb4'rejected',_utf8mb4'superseded')", name: "customer_ai_guidance_revisions_status"
  end

  create_table "customer_ai_profiles", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "active_guidance_revision_id"
    t.datetime "created_at", null: false
    t.bigint "customer_id", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "customer_id"], name: "index_customer_ai_profiles_on_account_customer", unique: true
    t.index ["account_id"], name: "index_customer_ai_profiles_on_account_id"
    t.index ["active_guidance_revision_id"], name: "index_customer_ai_profiles_on_active_revision", unique: true
    t.index ["customer_id"], name: "index_customer_ai_profiles_on_customer_id"
  end

  create_table "customer_ai_signals", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.integer "confidence_bps", null: false
    t.bigint "conversation_interpretation_id", null: false
    t.datetime "created_at", null: false
    t.bigint "customer_id", null: false
    t.datetime "decided_at"
    t.bigint "decided_by_user_id"
    t.json "decider_snapshot", null: false
    t.string "decision_idempotency_key", collation: "utf8mb4_0900_bin"
    t.text "decision_note"
    t.json "evidence", null: false
    t.string "idempotency_key", null: false, collation: "utf8mb4_0900_bin"
    t.json "proposed_guidance", null: false
    t.string "signal_type", null: false
    t.bigint "source_message_id", null: false
    t.string "status", default: "proposed", null: false
    t.bigint "target_outbound_message_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "customer_id", "status", "created_at"], name: "index_customer_ai_signals_on_customer_status"
    t.index ["account_id", "decision_idempotency_key"], name: "index_customer_ai_signals_on_decision_key", unique: true
    t.index ["account_id"], name: "index_customer_ai_signals_on_account_id"
    t.index ["conversation_interpretation_id", "idempotency_key"], name: "index_customer_ai_signals_on_interpretation_key", unique: true
    t.index ["conversation_interpretation_id"], name: "index_customer_ai_signals_on_conversation_interpretation_id"
    t.index ["customer_id"], name: "index_customer_ai_signals_on_customer_id"
    t.index ["decided_by_user_id"], name: "index_customer_ai_signals_on_decided_by_user_id"
    t.index ["source_message_id"], name: "index_customer_ai_signals_on_source_message_id"
    t.index ["target_outbound_message_id"], name: "index_customer_ai_signals_on_target_outbound_message_id"
    t.check_constraint "((`status` = _utf8mb4'proposed') and (`decided_at` is null) and (`decision_idempotency_key` is null)) or ((`status` <> _utf8mb4'proposed') and (`decided_at` is not null) and (`decision_idempotency_key` is not null))", name: "customer_ai_signals_decision"
    t.check_constraint "(`confidence_bps` >= 0) and (`confidence_bps` <= 10000)", name: "customer_ai_signals_confidence"
    t.check_constraint "`signal_type` in (_utf8mb4'positive_response',_utf8mb4'negative_response',_utf8mb4'factual_correction',_utf8mb4'tone_preference',_utf8mb4'language_preference',_utf8mb4'salutation_preference',_utf8mb4'concision_preference',_utf8mb4'unclear')", name: "customer_ai_signals_type"
    t.check_constraint "`status` in (_utf8mb4'proposed',_utf8mb4'approved',_utf8mb4'rejected',_utf8mb4'superseded')", name: "customer_ai_signals_status"
  end

  create_table "customer_email_addresses", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "customer_id", null: false
    t.string "email", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id", "email"], name: "index_customer_email_addresses_on_customer_id_and_email", unique: true
    t.index ["customer_id"], name: "index_customer_email_addresses_on_customer_id"
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

  create_table "email_connections", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.text "access_token"
    t.bigint "account_id", null: false
    t.string "connected_email", null: false
    t.datetime "created_at", null: false
    t.integer "credential_generation", default: 0, null: false
    t.string "inbound_cursor", collation: "utf8mb4_0900_bin"
    t.datetime "inbound_enabled_at"
    t.datetime "inbound_sync_enqueued_at"
    t.string "inbound_sync_job_id", collation: "utf8mb4_0900_bin"
    t.text "last_error"
    t.datetime "last_inbound_attempted_at"
    t.text "last_inbound_error"
    t.datetime "last_inbound_synced_at"
    t.string "provider", null: false
    t.string "provider_account_id", collation: "utf8mb4_0900_bin"
    t.string "provider_display_name"
    t.text "refresh_token"
    t.json "scopes", null: false
    t.string "status", default: "pending", null: false
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_email_connections_on_account_id", unique: true
    t.index ["provider", "provider_account_id"], name: "index_email_connections_on_provider_account"
    t.index ["provider", "status"], name: "index_email_connections_on_provider_and_status"
  end

  create_table "email_message_receipts", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.integer "attempts", default: 0, null: false
    t.bigint "conversation_message_id"
    t.datetime "created_at", null: false
    t.string "direction"
    t.datetime "discovered_at", null: false
    t.integer "email_connection_generation", null: false
    t.bigint "email_connection_id", null: false
    t.text "last_error"
    t.json "metadata", null: false
    t.datetime "next_retry_at"
    t.datetime "post_processing_enqueued_at"
    t.string "post_processing_enqueued_job_id", collation: "utf8mb4_0900_bin"
    t.datetime "post_processing_finalized_at"
    t.string "post_processing_job_id", collation: "utf8mb4_0900_bin"
    t.datetime "post_processing_started_at"
    t.datetime "processed_at"
    t.datetime "processing_enqueued_at"
    t.string "processing_enqueued_job_id", collation: "utf8mb4_0900_bin"
    t.string "processing_job_id", collation: "utf8mb4_0900_bin"
    t.datetime "processing_started_at"
    t.string "provider_account_id", null: false, collation: "utf8mb4_0900_bin"
    t.string "provider_history_id", collation: "utf8mb4_0900_bin"
    t.string "provider_message_id", null: false, collation: "utf8mb4_0900_bin"
    t.string "provider_thread_id", collation: "utf8mb4_0900_bin"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "fk_rails_40541bf8eb"
    t.index ["conversation_message_id"], name: "index_email_message_receipts_on_conversation_message_id"
    t.index ["email_connection_id", "provider_account_id", "provider_message_id"], name: "index_email_receipts_on_connection_message", unique: true
    t.index ["status", "next_retry_at", "id"], name: "index_email_receipts_for_retry"
    t.index ["status", "post_processing_finalized_at"], name: "index_email_receipts_on_post_processing"
    t.index ["status", "processing_started_at"], name: "index_email_receipts_for_stale_processing"
  end

  create_table "external_identities", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address"
    t.bigint "identity_id", null: false
    t.string "provider", null: false
    t.string "subject", null: false, collation: "utf8mb4_0900_bin"
    t.datetime "updated_at", null: false
    t.index ["identity_id", "provider"], name: "index_external_identities_on_identity_id_and_provider", unique: true
    t.index ["identity_id"], name: "index_external_identities_on_identity_id"
    t.index ["provider", "subject"], name: "index_external_identities_on_provider_and_subject", unique: true
  end

  create_table "identities", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_identities_on_email_address", unique: true
  end

  create_table "invoice_reminder_notification_deliveries", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "attempt_token", collation: "utf8mb4_0900_bin"
    t.integer "attempts", default: 0, null: false
    t.integer "build_attempts", default: 0, null: false
    t.datetime "build_started_at"
    t.string "build_token", collation: "utf8mb4_0900_bin"
    t.datetime "canceled_at"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.datetime "delivery_started_at"
    t.string "event_name", null: false
    t.datetime "failed_at"
    t.bigint "invoice_reminder_id", null: false
    t.string "last_error_class"
    t.text "last_error_message"
    t.datetime "next_retry_at"
    t.string "recipient_email", null: false
    t.bigint "recipient_user_id"
    t.bigint "recipient_user_snapshot_id", null: false
    t.datetime "retry_enqueued_at"
    t.string "retry_job_id", collation: "utf8mb4_0900_bin"
    t.integer "scheduling_failures", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.string "terminal_reason"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_invoice_reminder_notification_deliveries_on_account_id"
    t.index ["invoice_reminder_id", "recipient_user_snapshot_id", "event_name"], name: "index_reminder_notification_deliveries_on_recipient", unique: true
    t.index ["invoice_reminder_id"], name: "idx_on_invoice_reminder_id_b333dcf0cd"
    t.index ["recipient_user_id"], name: "idx_on_recipient_user_id_5e68a810d1"
    t.index ["status", "build_started_at", "build_token"], name: "index_reminder_notification_deliveries_on_stale_build"
    t.index ["status", "delivery_started_at"], name: "index_reminder_notification_deliveries_on_status"
    t.index ["status", "retry_enqueued_at", "retry_job_id"], name: "index_reminder_notification_deliveries_on_stale_retry"
    t.index ["status", "retry_job_id", "next_retry_at"], name: "index_reminder_notification_deliveries_on_due_retry"
    t.check_constraint "(`attempts` >= 0) and (`attempts` <= 5)", name: "invoice_reminder_notification_deliveries_attempts"
    t.check_constraint "(`build_attempts` >= 0) and (`build_attempts` <= 5)", name: "invoice_reminder_notification_deliveries_build_attempts"
    t.check_constraint "`scheduling_failures` >= 0", name: "invoice_reminder_notification_deliveries_scheduling_failures"
    t.check_constraint "`status` in (_utf8mb4'pending',_utf8mb4'delivering',_utf8mb4'delivered',_utf8mb4'uncertain',_utf8mb4'failed',_utf8mb4'canceled')", name: "invoice_reminder_notification_deliveries_status"
  end

  create_table "invoice_reminder_suppressions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.integer "day_offset", null: false
    t.bigint "invoice_id", null: false
    t.bigint "invoice_schedule_id"
    t.string "reason", null: false
    t.string "stage_key", null: false
    t.datetime "suppressed_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_invoice_reminder_suppressions_on_account_id"
    t.index ["invoice_id", "invoice_schedule_id"], name: "index_reminder_suppressions_on_invoice_and_schedule", unique: true
    t.index ["invoice_id", "stage_key"], name: "index_reminder_suppressions_on_invoice_and_stage", unique: true
    t.index ["invoice_id"], name: "index_invoice_reminder_suppressions_on_invoice_id"
    t.index ["invoice_schedule_id"], name: "index_invoice_reminder_suppressions_on_invoice_schedule_id"
    t.check_constraint "`day_offset` > 0", name: "invoice_reminder_suppressions_day_offset_positive"
  end

  create_table "invoice_reminders", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "category", null: false
    t.bigint "conversation_message_id", null: false
    t.datetime "created_at", null: false
    t.integer "day_offset", null: false
    t.bigint "invoice_id", null: false
    t.bigint "invoice_schedule_id"
    t.datetime "notifications_finalized_at"
    t.datetime "notifications_initialized_at"
    t.string "stage_key", null: false
    t.boolean "terminal_at_delivery"
    t.string "tone"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_invoice_reminders_on_account_id"
    t.index ["conversation_message_id"], name: "index_invoice_reminders_on_conversation_message_id", unique: true
    t.index ["invoice_id", "invoice_schedule_id"], name: "index_invoice_reminders_on_invoice_and_schedule", unique: true
    t.index ["invoice_id", "stage_key"], name: "index_invoice_reminders_on_invoice_id_and_stage_key", unique: true
    t.index ["invoice_id"], name: "index_invoice_reminders_on_invoice_id"
    t.index ["invoice_schedule_id"], name: "index_invoice_reminders_on_invoice_schedule_id"
    t.index ["notifications_finalized_at", "notifications_initialized_at"], name: "index_invoice_reminders_on_notification_state"
  end

  create_table "invoice_schedules", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.integer "day_offset", null: false
    t.string "kind", null: false
    t.string "tone", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "kind", "category", "day_offset"], name: "index_invoice_schedules_on_account_and_stage", unique: true
    t.index ["account_id"], name: "index_invoice_schedules_on_account_id"
    t.check_constraint "`day_offset` > 0", name: "invoice_schedules_day_offset_positive"
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
    t.index ["provider", "external_account_id"], name: "index_invoice_sources_on_provider_and_external_account_id", unique: true
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
    t.bigint "customer_id", null: false
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

  create_table "notification_subscriptions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "email", default: false, null: false
    t.string "event", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "event"], name: "index_notification_subscriptions_on_user_id_and_event", unique: true
    t.index ["user_id"], name: "index_notification_subscriptions_on_user_id"
  end

  create_table "payment_promises", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "active_invoice_id"
    t.datetime "created_at", null: false
    t.bigint "follow_up_message_id"
    t.date "follow_up_on", null: false
    t.bigint "invoice_id", null: false
    t.date "promised_on", null: false
    t.bigint "source_message_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_payment_promises_on_account_id"
    t.index ["active_invoice_id"], name: "index_payment_promises_on_active_invoice_id", unique: true
    t.index ["follow_up_message_id"], name: "index_payment_promises_on_follow_up_message_id", unique: true
    t.index ["invoice_id", "status", "follow_up_on"], name: "index_payment_promises_on_invoice_status_and_follow_up"
    t.index ["invoice_id"], name: "index_payment_promises_on_invoice_id"
    t.index ["source_message_id"], name: "index_payment_promises_on_source_message_id", unique: true
    t.index ["status", "follow_up_on"], name: "index_payment_promises_on_due_follow_up"
    t.check_constraint "((`status` = _utf8mb4'active') and (`active_invoice_id` is not null) and (`active_invoice_id` = `invoice_id`)) or ((`status` <> _utf8mb4'active') and (`active_invoice_id` is null))", name: "payment_promises_active_invoice_matches_status"
  end

  create_table "platform_admin_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.string "action", null: false
    t.string "actor_email_address", null: false
    t.bigint "actor_identity_id"
    t.datetime "created_at", null: false
    t.json "metadata", null: false
    t.bigint "target_id"
    t.string "target_type"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_platform_admin_events_on_account_id"
    t.index ["action", "created_at"], name: "index_platform_admin_events_on_action_and_created_at"
    t.index ["actor_identity_id"], name: "index_platform_admin_events_on_actor_identity_id"
    t.index ["target_type", "target_id"], name: "index_platform_admin_events_on_target_type_and_target_id"
  end

  create_table "sessions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "identity_id", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["identity_id"], name: "index_sessions_on_identity_id"
  end

  create_table "stripe_installation_claims", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "account_id"
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.boolean "livemode", null: false
    t.string "request_digest", limit: 64, null: false
    t.string "stripe_account_id", null: false
    t.string "stripe_user_id", null: false
    t.string "token_digest", limit: 64, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_stripe_installation_claims_on_account_id"
    t.index ["expires_at"], name: "index_stripe_installation_claims_on_expires_at"
    t.index ["request_digest"], name: "index_stripe_installation_claims_on_request_digest", unique: true
    t.index ["stripe_account_id", "livemode"], name: "idx_on_stripe_account_id_livemode_2fff42ae45"
    t.index ["token_digest"], name: "index_stripe_installation_claims_on_token_digest", unique: true
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

  add_foreign_key "collection_holds", "accounts"
  add_foreign_key "collection_holds", "conversation_actions", on_delete: :nullify
  add_foreign_key "collection_holds", "conversation_messages", column: "source_message_id", on_delete: :nullify
  add_foreign_key "collection_holds", "conversations"
  add_foreign_key "collection_holds", "customers"
  add_foreign_key "collection_holds", "invoices"
  add_foreign_key "collection_holds", "users", column: "placed_by_user_id"
  add_foreign_key "collection_holds", "users", column: "released_by_user_id"
  add_foreign_key "conversation_action_executions", "accounts"
  add_foreign_key "conversation_action_executions", "collection_holds", on_delete: :nullify
  add_foreign_key "conversation_action_executions", "conversation_action_revisions"
  add_foreign_key "conversation_action_executions", "conversation_actions"
  add_foreign_key "conversation_action_executions", "conversation_escalations", column: "delivery_escalation_id", on_delete: :nullify
  add_foreign_key "conversation_action_executions", "conversation_escalations", column: "effect_escalation_id", on_delete: :nullify
  add_foreign_key "conversation_action_executions", "customer_email_addresses", on_delete: :nullify
  add_foreign_key "conversation_action_executions", "payment_promises", on_delete: :nullify
  add_foreign_key "conversation_action_executions", "users", column: "approved_by_user_id", on_delete: :nullify
  add_foreign_key "conversation_action_revisions", "conversation_actions"
  add_foreign_key "conversation_action_revisions", "customers"
  add_foreign_key "conversation_action_revisions", "invoices"
  add_foreign_key "conversation_action_revisions", "users", column: "author_user_id"
  add_foreign_key "conversation_actions", "accounts"
  add_foreign_key "conversation_actions", "conversation_action_revisions", column: "decided_revision_id", on_delete: :nullify
  add_foreign_key "conversation_actions", "conversation_messages", column: "source_message_id", on_delete: :nullify
  add_foreign_key "conversation_actions", "conversations"
  add_foreign_key "conversation_actions", "users", column: "created_by_user_id"
  add_foreign_key "conversation_actions", "users", column: "decided_by_user_id", on_delete: :nullify
  add_foreign_key "conversation_ai_evaluations", "accounts"
  add_foreign_key "conversation_ai_evaluations", "conversation_ai_evaluations", column: "supersedes_evaluation_id", on_delete: :nullify
  add_foreign_key "conversation_ai_evaluations", "conversation_ai_plans"
  add_foreign_key "conversation_ai_evaluations", "conversation_interpretations"
  add_foreign_key "conversation_ai_evaluations", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "conversation_ai_invocations", "accounts"
  add_foreign_key "conversation_ai_invocations", "conversation_interpretations"
  add_foreign_key "conversation_ai_plans", "accounts"
  add_foreign_key "conversation_ai_plans", "conversation_interpretations"
  add_foreign_key "conversation_escalations", "accounts"
  add_foreign_key "conversation_escalations", "collection_holds", on_delete: :nullify
  add_foreign_key "conversation_escalations", "conversation_actions", on_delete: :nullify
  add_foreign_key "conversation_escalations", "conversation_messages", column: "source_message_id", on_delete: :nullify
  add_foreign_key "conversation_escalations", "conversations"
  add_foreign_key "conversation_escalations", "customers"
  add_foreign_key "conversation_escalations", "invoices"
  add_foreign_key "conversation_escalations", "users", column: "opened_by_user_id"
  add_foreign_key "conversation_escalations", "users", column: "resolved_by_user_id"
  add_foreign_key "conversation_events", "accounts"
  add_foreign_key "conversation_events", "conversation_messages", on_delete: :nullify
  add_foreign_key "conversation_events", "conversations"
  add_foreign_key "conversation_events", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "conversation_interpretations", "accounts"
  add_foreign_key "conversation_interpretations", "conversation_interpretations", column: "supersedes_interpretation_id", on_delete: :nullify
  add_foreign_key "conversation_interpretations", "conversation_messages", column: "source_message_id"
  add_foreign_key "conversation_interpretations", "conversations"
  add_foreign_key "conversation_interpretations", "customer_ai_guidance_revisions", on_delete: :nullify
  add_foreign_key "conversation_interpretations", "customers", on_delete: :nullify
  add_foreign_key "conversation_interpretations", "invoices", on_delete: :nullify
  add_foreign_key "conversation_messages", "accounts"
  add_foreign_key "conversation_messages", "conversation_action_executions", on_delete: :nullify
  add_foreign_key "conversation_messages", "conversation_messages", column: "reply_to_message_id"
  add_foreign_key "conversation_messages", "conversations"
  add_foreign_key "conversation_messages", "email_connections", on_delete: :nullify
  add_foreign_key "conversation_messages", "invoices"
  add_foreign_key "conversation_messages", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "conversation_messages", "users", column: "reviewed_by_user_id", on_delete: :nullify
  add_foreign_key "conversations", "accounts"
  add_foreign_key "conversations", "conversations", column: "canonical_conversation_id"
  add_foreign_key "conversations", "customers", on_delete: :nullify
  add_foreign_key "conversations", "invoices"
  add_foreign_key "customer_ai_guidance_revisions", "accounts"
  add_foreign_key "customer_ai_guidance_revisions", "customer_ai_profiles"
  add_foreign_key "customer_ai_guidance_revisions", "customer_ai_signals", column: "source_signal_id", on_delete: :nullify
  add_foreign_key "customer_ai_guidance_revisions", "users", column: "author_user_id", on_delete: :nullify
  add_foreign_key "customer_ai_profiles", "accounts"
  add_foreign_key "customer_ai_profiles", "customer_ai_guidance_revisions", column: "active_guidance_revision_id", on_delete: :nullify
  add_foreign_key "customer_ai_profiles", "customers"
  add_foreign_key "customer_ai_signals", "accounts"
  add_foreign_key "customer_ai_signals", "conversation_interpretations"
  add_foreign_key "customer_ai_signals", "conversation_messages", column: "source_message_id"
  add_foreign_key "customer_ai_signals", "conversation_messages", column: "target_outbound_message_id"
  add_foreign_key "customer_ai_signals", "customers"
  add_foreign_key "customer_ai_signals", "users", column: "decided_by_user_id", on_delete: :nullify
  add_foreign_key "customer_email_addresses", "customers", on_delete: :cascade
  add_foreign_key "customer_segments", "accounts"
  add_foreign_key "customers", "accounts"
  add_foreign_key "customers", "customer_segments"
  add_foreign_key "customers", "invoice_sources"
  add_foreign_key "email_connections", "accounts"
  add_foreign_key "email_message_receipts", "accounts"
  add_foreign_key "email_message_receipts", "conversation_messages", on_delete: :nullify
  add_foreign_key "email_message_receipts", "email_connections"
  add_foreign_key "external_identities", "identities", on_delete: :cascade
  add_foreign_key "invoice_reminder_notification_deliveries", "accounts"
  add_foreign_key "invoice_reminder_notification_deliveries", "invoice_reminders"
  add_foreign_key "invoice_reminder_notification_deliveries", "users", column: "recipient_user_id", on_delete: :nullify
  add_foreign_key "invoice_reminder_suppressions", "accounts"
  add_foreign_key "invoice_reminder_suppressions", "invoice_schedules", on_delete: :nullify
  add_foreign_key "invoice_reminder_suppressions", "invoices"
  add_foreign_key "invoice_reminders", "accounts"
  add_foreign_key "invoice_reminders", "conversation_messages"
  add_foreign_key "invoice_reminders", "invoice_schedules", on_delete: :nullify
  add_foreign_key "invoice_reminders", "invoices"
  add_foreign_key "invoice_schedules", "accounts"
  add_foreign_key "invoice_source_webhook_events", "invoice_sources"
  add_foreign_key "invoice_sources", "accounts"
  add_foreign_key "invoices", "accounts"
  add_foreign_key "invoices", "customers"
  add_foreign_key "invoices", "invoice_sources"
  add_foreign_key "magic_links", "identities"
  add_foreign_key "notification_subscriptions", "users", on_delete: :cascade
  add_foreign_key "payment_promises", "accounts"
  add_foreign_key "payment_promises", "conversation_messages", column: "follow_up_message_id"
  add_foreign_key "payment_promises", "conversation_messages", column: "source_message_id"
  add_foreign_key "payment_promises", "invoices"
  add_foreign_key "payment_promises", "invoices", column: "active_invoice_id"
  add_foreign_key "platform_admin_events", "accounts", on_delete: :nullify
  add_foreign_key "platform_admin_events", "identities", column: "actor_identity_id", on_delete: :nullify
  add_foreign_key "sessions", "identities"
  add_foreign_key "stripe_installation_claims", "accounts", on_delete: :nullify
  add_foreign_key "users", "accounts"
  add_foreign_key "users", "identities"
end

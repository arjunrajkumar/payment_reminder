class CreateConversationAiShadowFoundation < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts,
      :conversation_ai_mode,
      :string,
      null: false,
      default: "off"
    add_column :accounts, :conversation_ai_provider, :string
    add_column :accounts, :time_zone, :string, null: false, default: "UTC"
    add_column :accounts, :conversation_ai_enabled_at, :datetime
    add_check_constraint :accounts,
      "conversation_ai_mode IN ('off', 'shadow')",
      name: "accounts_conversation_ai_mode"

    create_table :customer_ai_profiles do |t|
      t.references :account, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.bigint :active_guidance_revision_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps

      t.index %i[account_id customer_id],
        unique: true,
        name: "index_customer_ai_profiles_on_account_customer"
      t.index :active_guidance_revision_id,
        unique: true,
        name: "index_customer_ai_profiles_on_active_revision"
    end

    create_table :customer_ai_guidance_revisions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :customer_ai_profile, null: false, foreign_key: true
      t.integer :revision_number, null: false
      t.string :status, null: false
      t.string :author_kind, null: false
      t.references :author_user,
        foreign_key: { to_table: :users, on_delete: :nullify }
      t.json :author_snapshot, null: false
      t.string :summary, null: false, limit: 500
      t.json :structured_guidance, null: false
      t.json :evidence_snapshot, null: false
      t.string :idempotency_key,
        null: false,
        collation: "utf8mb4_0900_bin"
      t.datetime :activated_at
      t.datetime :rejected_at
      t.datetime :superseded_at
      t.timestamps

      t.index %i[customer_ai_profile_id revision_number],
        unique: true,
        name: "index_customer_ai_guidance_on_profile_revision"
      t.index %i[customer_ai_profile_id idempotency_key],
        unique: true,
        name: "index_customer_ai_guidance_on_profile_idempotency"
      t.index %i[account_id status created_at],
        name: "index_customer_ai_guidance_on_account_status"
      t.check_constraint(
        "status IN ('proposed', 'active', 'rejected', 'superseded')",
        name: "customer_ai_guidance_revisions_status"
      )
      t.check_constraint(
        "author_kind IN ('user', 'ai')",
        name: "customer_ai_guidance_revisions_author_kind"
      )
      t.check_constraint(
        "revision_number > 0",
        name: "customer_ai_guidance_revisions_number"
      )
      t.check_constraint(
        "(status = 'active' AND activated_at IS NOT NULL " \
          "AND rejected_at IS NULL AND superseded_at IS NULL) OR " \
        "(status = 'rejected' AND rejected_at IS NOT NULL " \
          "AND activated_at IS NULL AND superseded_at IS NULL) OR " \
        "(status = 'superseded' AND superseded_at IS NOT NULL " \
          "AND activated_at IS NOT NULL AND rejected_at IS NULL) OR " \
        "(status = 'proposed' AND activated_at IS NULL " \
          "AND rejected_at IS NULL AND superseded_at IS NULL)",
        name: "customer_ai_guidance_revisions_lifecycle"
      )
    end

    create_table :conversation_interpretations do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true
      t.references :source_message,
        null: false,
        foreign_key: { to_table: :conversation_messages }
      t.references :invoice, foreign_key: { on_delete: :nullify }
      t.references :customer, foreign_key: { on_delete: :nullify }
      t.references :supersedes_interpretation,
        foreign_key: {
          to_table: :conversation_interpretations,
          on_delete: :nullify
        }
      t.references :customer_ai_guidance_revision,
        foreign_key: { on_delete: :nullify }
      t.string :requested_mode, null: false, default: "shadow"
      t.string :status, null: false, default: "pending"
      t.string :analysis_key,
        null: false,
        collation: "utf8mb4_0900_bin"
      t.string :input_digest, collation: "utf8mb4_0900_bin"
      t.json :context_snapshot, null: false
      t.text :authored_content_snapshot
      t.json :authored_content_warnings, null: false
      t.json :source_identity_snapshot, null: false
      t.string :semantic_prompt_version, null: false
      t.string :provider_adapter_version, null: false
      t.string :result_schema_version, null: false
      t.string :planner_version, null: false
      t.string :catalog_version, null: false
      t.string :provider, null: false
      t.string :requested_model, null: false
      t.string :accepted_model

      t.string :scheduling_status, null: false, default: "reserved"
      t.integer :scheduling_attempts, null: false, default: 0
      t.integer :scheduling_generation, null: false, default: 0
      t.string :scheduling_token, collation: "utf8mb4_0900_bin"
      t.datetime :scheduling_claimed_at
      t.datetime :scheduling_enqueued_at
      t.datetime :scheduling_consumed_at
      t.datetime :next_scheduling_at
      t.string :last_scheduling_error, limit: 2_000

      t.integer :provider_attempts, null: false, default: 0
      t.integer :claim_generation, null: false, default: 0
      t.string :claim_token, collation: "utf8mb4_0900_bin"
      t.datetime :claimed_at
      t.datetime :next_retry_at

      t.string :message_kind
      t.string :language
      t.integer :overall_confidence_bps
      t.boolean :requires_human
      t.string :summary, limit: 1_000
      t.text :concise_rationale
      t.json :reason_codes, null: false
      t.json :structured_result, null: false
      t.string :failure_category
      t.text :failure_reason
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :canceled_at
      t.datetime :superseded_at
      t.datetime :finalized_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps

      t.index %i[account_id analysis_key],
        unique: true,
        name: "index_interpretations_on_account_analysis_key"
      t.index %i[account_id source_message_id created_at],
        name: "index_interpretations_on_source_history"
      t.index %i[account_id conversation_id status created_at],
        name: "index_interpretations_on_conversation_status"
      t.index %i[account_id status completed_at id],
        name: "index_interpretations_on_account_status"
      t.index %i[scheduling_status next_scheduling_at id],
        name: "index_interpretations_on_due_scheduling"
      t.index %i[scheduling_status scheduling_claimed_at id],
        name: "index_interpretations_on_stale_scheduling"
      t.index %i[scheduling_status scheduling_enqueued_at scheduling_consumed_at id],
        name: "index_interpretations_on_lost_scheduling"
      t.index %i[status claimed_at id],
        name: "index_interpretations_on_stale_claims"
      t.index %i[status next_retry_at id],
        name: "index_interpretations_on_due_retry"
      t.index %i[status finalized_at id],
        name: "index_interpretations_on_finalization"
      t.index %i[account_id provider requested_model semantic_prompt_version],
        name: "index_interpretations_on_report_versions"
      t.check_constraint(
        "requested_mode = 'shadow'",
        name: "conversation_interpretations_mode"
      )
      t.check_constraint(
        "status IN ('pending', 'running', 'succeeded', 'failed', " \
          "'canceled', 'superseded', 'skipped')",
        name: "conversation_interpretations_status"
      )
      t.check_constraint(
        "scheduling_status IN ('reserved', 'claimed', 'enqueued', " \
          "'consumed', 'exhausted', 'canceled')",
        name: "conversation_interpretations_scheduling_status"
      )
      t.check_constraint(
        "scheduling_attempts >= 0 AND scheduling_attempts <= 5 " \
          "AND scheduling_generation >= 0 AND provider_attempts >= 0 " \
          "AND provider_attempts <= 5 AND claim_generation >= 0",
        name: "conversation_interpretations_attempts"
      )
      t.check_constraint(
        "overall_confidence_bps IS NULL OR " \
          "(overall_confidence_bps >= 0 AND overall_confidence_bps <= 10000)",
        name: "conversation_interpretations_confidence"
      )
      t.check_constraint(
        "(status = 'running' AND claim_token IS NOT NULL " \
          "AND claimed_at IS NOT NULL) OR " \
        "(status <> 'running' AND claim_token IS NULL AND claimed_at IS NULL)",
        name: "conversation_interpretations_claim"
      )
      t.check_constraint(
        "(scheduling_status = 'claimed' AND scheduling_token IS NOT NULL " \
          "AND scheduling_claimed_at IS NOT NULL) OR " \
        "(scheduling_status <> 'claimed' AND scheduling_token IS NULL " \
          "AND scheduling_claimed_at IS NULL)",
        name: "conversation_interpretations_schedule_claim"
      )
      t.check_constraint(
        "(status IN ('succeeded', 'failed', 'skipped') " \
          "AND completed_at IS NOT NULL) OR " \
        "(status = 'canceled' AND canceled_at IS NOT NULL) OR " \
        "(status = 'superseded' AND superseded_at IS NOT NULL) OR " \
        "(status IN ('pending', 'running') AND completed_at IS NULL " \
          "AND canceled_at IS NULL AND superseded_at IS NULL)",
        name: "conversation_interpretations_terminal"
      )
    end

    create_table :conversation_ai_invocations do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation_interpretation, null: false, foreign_key: true
      t.integer :attempt_number, null: false
      t.integer :claim_generation, null: false
      t.string :attempt_token,
        null: false,
        collation: "utf8mb4_0900_bin"
      t.string :provider, null: false
      t.string :endpoint, null: false
      t.string :api_version, null: false
      t.string :provider_adapter_version, null: false
      t.string :requested_model, null: false
      t.string :returned_model
      t.string :application_request_id,
        null: false,
        collation: "utf8mb4_0900_bin"
      t.string :provider_request_id
      t.string :status, null: false, default: "started"
      t.json :sanitized_request, null: false
      t.json :sanitized_response, null: false
      t.integer :response_status
      t.string :failure_category
      t.string :failure_class
      t.string :failure_message, limit: 2_000
      t.integer :input_tokens
      t.integer :cached_input_tokens
      t.integer :output_tokens
      t.integer :total_tokens
      t.integer :latency_ms
      t.integer :retry_after_seconds
      t.boolean :possible_duplicate_cost, null: false, default: false
      t.json :provider_metadata, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps

      t.index %i[conversation_interpretation_id attempt_number],
        unique: true,
        name: "index_ai_invocations_on_interpretation_attempt"
      t.index :application_request_id,
        unique: true,
        name: "index_ai_invocations_on_application_request"
      t.index %i[account_id status created_at],
        name: "index_ai_invocations_on_account_status"
      t.check_constraint(
        "status IN ('started', 'succeeded', 'failed', 'uncertain', 'superseded')",
        name: "conversation_ai_invocations_status"
      )
      t.check_constraint(
        "attempt_number > 0 AND attempt_number <= 5 AND claim_generation >= 0",
        name: "conversation_ai_invocations_attempt"
      )
      t.check_constraint(
        "(status = 'started' AND finished_at IS NULL) OR " \
          "(status <> 'started' AND finished_at IS NOT NULL)",
        name: "conversation_ai_invocations_finished"
      )
    end

    create_table :conversation_ai_plans do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation_interpretation,
        null: false,
        foreign_key: true,
        index: { unique: true }
      t.string :decision, null: false
      t.string :proposed_action_type
      t.json :arguments, null: false
      t.json :proposed_reply, null: false
      t.string :user_facing_summary, null: false, limit: 1_000
      t.json :planner_reason_codes, null: false
      t.integer :confidence_bps
      t.string :planner_version, null: false
      t.string :catalog_version, null: false
      t.string :status, null: false, default: "current"
      t.datetime :superseded_at
      t.timestamps

      t.index %i[account_id decision created_at],
        name: "index_ai_plans_on_account_decision"
      t.check_constraint(
        "decision IN ('propose_action', 'human_review', 'no_action')",
        name: "conversation_ai_plans_decision"
      )
      t.check_constraint(
        "status IN ('current', 'superseded')",
        name: "conversation_ai_plans_status"
      )
      t.check_constraint(
        "confidence_bps IS NULL OR " \
          "(confidence_bps >= 0 AND confidence_bps <= 10000)",
        name: "conversation_ai_plans_confidence"
      )
      t.check_constraint(
        "(decision = 'propose_action' AND proposed_action_type IS NOT NULL) OR " \
          "(decision <> 'propose_action' AND proposed_action_type IS NULL)",
        name: "conversation_ai_plans_action"
      )
      t.check_constraint(
        "(status = 'current' AND superseded_at IS NULL) OR " \
          "(status = 'superseded' AND superseded_at IS NOT NULL)",
        name: "conversation_ai_plans_lifecycle"
      )
    end

    create_table :conversation_ai_evaluations do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation_interpretation, null: false, foreign_key: true
      t.references :conversation_ai_plan, null: false, foreign_key: true
      t.references :actor_user,
        foreign_key: { to_table: :users, on_delete: :nullify }
      t.json :actor_snapshot, null: false
      t.string :verdict, null: false
      t.string :corrected_message_kind
      t.string :corrected_action_type
      t.json :corrected_arguments, null: false
      t.text :note
      t.string :idempotency_key,
        null: false,
        collation: "utf8mb4_0900_bin"
      t.references :supersedes_evaluation,
        foreign_key: {
          to_table: :conversation_ai_evaluations,
          on_delete: :nullify
        }
      t.timestamps

      t.index %i[account_id idempotency_key],
        unique: true,
        name: "index_ai_evaluations_on_account_idempotency"
      t.index %i[conversation_interpretation_id created_at],
        name: "index_ai_evaluations_on_interpretation_history"
      t.check_constraint(
        "verdict IN ('correct', 'incorrect', 'unsure')",
        name: "conversation_ai_evaluations_verdict"
      )
    end

    create_table :customer_ai_signals do |t|
      t.references :account, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.references :conversation_interpretation, null: false, foreign_key: true
      t.references :source_message,
        null: false,
        foreign_key: { to_table: :conversation_messages }
      t.references :target_outbound_message,
        null: false,
        foreign_key: { to_table: :conversation_messages }
      t.string :signal_type, null: false
      t.integer :confidence_bps, null: false
      t.json :evidence, null: false
      t.json :proposed_guidance, null: false
      t.string :status, null: false, default: "proposed"
      t.references :decided_by_user,
        foreign_key: { to_table: :users, on_delete: :nullify }
      t.json :decider_snapshot, null: false
      t.datetime :decided_at
      t.text :decision_note
      t.string :decision_idempotency_key,
        collation: "utf8mb4_0900_bin"
      t.string :idempotency_key,
        null: false,
        collation: "utf8mb4_0900_bin"
      t.timestamps

      t.index %i[conversation_interpretation_id idempotency_key],
        unique: true,
        name: "index_customer_ai_signals_on_interpretation_key"
      t.index %i[account_id customer_id status created_at],
        name: "index_customer_ai_signals_on_customer_status"
      t.index %i[account_id decision_idempotency_key],
        unique: true,
        name: "index_customer_ai_signals_on_decision_key"
      t.check_constraint(
        "signal_type IN ('positive_response', 'negative_response', " \
          "'factual_correction', 'tone_preference', 'language_preference', " \
          "'salutation_preference', 'concision_preference', 'unclear')",
        name: "customer_ai_signals_type"
      )
      t.check_constraint(
        "status IN ('proposed', 'approved', 'rejected', 'superseded')",
        name: "customer_ai_signals_status"
      )
      t.check_constraint(
        "confidence_bps >= 0 AND confidence_bps <= 10000",
        name: "customer_ai_signals_confidence"
      )
      t.check_constraint(
        "(status = 'proposed' AND decided_at IS NULL " \
          "AND decision_idempotency_key IS NULL) OR " \
          "(status <> 'proposed' AND decided_at IS NOT NULL " \
          "AND decision_idempotency_key IS NOT NULL)",
        name: "customer_ai_signals_decision"
      )
    end

    add_reference :customer_ai_guidance_revisions,
      :source_signal,
      foreign_key: {
        to_table: :customer_ai_signals,
        on_delete: :nullify
      }
    add_foreign_key :customer_ai_profiles,
      :customer_ai_guidance_revisions,
      column: :active_guidance_revision_id,
      on_delete: :nullify

    add_column :conversation_events,
      :ai_event_key,
      :string,
      collation: "utf8mb4_0900_bin"
    add_index :conversation_events,
      :ai_event_key,
      unique: true,
      name: "index_conversation_events_on_ai_event_key"
  end
end

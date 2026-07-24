class CreateConversationActionExecutions < ActiveRecord::Migration[8.1]
  def change
    create_table :conversation_action_executions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation_action,
        null: false,
        foreign_key: true,
        index: { unique: true }
      t.references :conversation_action_revision,
        null: false,
        foreign_key: true,
        index: { unique: true }
      t.references :approved_by_user,
        foreign_key: { to_table: :users, on_delete: :nullify }
      t.json :approver_snapshot, null: false

      t.string :status, null: false, default: "pending"
      t.string :phase, null: false, default: "effect"
      t.integer :attempts, null: false, default: 0
      t.integer :claim_generation, null: false, default: 0
      t.string :claim_token, collation: "utf8mb4_0900_bin"
      t.datetime :claimed_at
      t.datetime :next_retry_at

      t.string :scheduling_status, null: false, default: "reserved"
      t.integer :scheduling_generation, null: false, default: 0
      t.string :scheduling_token, collation: "utf8mb4_0900_bin"
      t.datetime :scheduling_claimed_at
      t.integer :scheduling_attempts, null: false, default: 0
      t.datetime :next_scheduling_at
      t.datetime :scheduled_at
      t.datetime :schedule_consumed_at
      t.string :last_scheduling_error, limit: 2_000

      t.datetime :effect_completed_at
      t.datetime :effect_applied_at
      t.string :result_code
      t.json :result_metadata, null: false
      t.json :reply_snapshot, null: false
      t.string :failure_category
      t.text :failure_reason
      t.datetime :finished_at

      t.string :finalization_status, null: false, default: "not_required"
      t.datetime :delivery_finalized_at
      t.boolean :attention_required, null: false, default: false
      t.integer :attention_version, null: false, default: 0
      t.integer :acknowledged_attention_version, null: false, default: 0

      t.references :payment_promise,
        foreign_key: { on_delete: :nullify }
      t.references :customer_email_address,
        foreign_key: { on_delete: :nullify }
      t.references :collection_hold,
        foreign_key: { on_delete: :nullify }
      t.references :effect_escalation,
        foreign_key: {
          to_table: :conversation_escalations,
          on_delete: :nullify
        }
      t.references :delivery_escalation,
        foreign_key: {
          to_table: :conversation_escalations,
          on_delete: :nullify
        }

      t.integer :lock_version, null: false, default: 0
      t.timestamps

      t.index %i[scheduling_status next_scheduling_at id],
        name: "index_action_executions_on_due_scheduling"
      t.index %i[scheduling_status scheduling_claimed_at id],
        name: "index_action_executions_on_stale_scheduling"
      t.index %i[scheduling_status scheduled_at schedule_consumed_at id],
        name: "index_action_executions_on_lost_scheduling"
      t.index %i[status phase next_retry_at id],
        name: "index_action_executions_on_pending_phase"
      t.index %i[status claimed_at id],
        name: "index_action_executions_on_stale_claims"
      t.index %i[finalization_status status id],
        name: "index_action_executions_on_finalization"

      t.check_constraint(
        "status IN ('pending', 'running', 'awaiting_delivery', " \
          "'succeeded', 'failed', 'uncertain', 'canceled')",
        name: "conversation_action_executions_status"
      )
      t.check_constraint(
        "phase IN ('effect', 'reply_reservation', 'delivery', 'finalized')",
        name: "conversation_action_executions_phase"
      )
      t.check_constraint(
        "scheduling_status IN ('reserved', 'claimed', 'enqueued', " \
          "'consumed', 'exhausted', 'canceled')",
        name: "conversation_action_executions_scheduling_status"
      )
      t.check_constraint(
        "finalization_status IN ('not_required', 'pending', 'completed')",
        name: "conversation_action_executions_finalization_status"
      )
      t.check_constraint(
        "attempts >= 0 AND attempts <= 5 AND claim_generation >= 0",
        name: "conversation_action_executions_attempts"
      )
      t.check_constraint(
        "scheduling_attempts >= 0 AND scheduling_attempts <= 5 " \
          "AND scheduling_generation >= 0",
        name: "conversation_action_executions_scheduling_attempts"
      )
      t.check_constraint(
        "(status = 'running' AND claim_token IS NOT NULL " \
          "AND claimed_at IS NOT NULL) OR " \
          "(status <> 'running' AND claim_token IS NULL " \
          "AND claimed_at IS NULL)",
        name: "conversation_action_executions_claim"
      )
      t.check_constraint(
        "(scheduling_status = 'claimed' AND scheduling_token IS NOT NULL " \
          "AND scheduling_claimed_at IS NOT NULL) OR " \
          "(scheduling_status <> 'claimed' AND scheduling_token IS NULL " \
          "AND scheduling_claimed_at IS NULL)",
        name: "conversation_action_executions_schedule_claim"
      )
      t.check_constraint(
        "(status IN ('succeeded', 'failed', 'uncertain', 'canceled') " \
          "AND finished_at IS NOT NULL AND phase = 'finalized') OR " \
          "(status NOT IN ('succeeded', 'failed', 'uncertain', 'canceled') " \
          "AND finished_at IS NULL AND phase <> 'finalized')",
        name: "conversation_action_executions_terminal"
      )
      t.check_constraint(
        "acknowledged_attention_version >= 0 AND " \
          "acknowledged_attention_version <= attention_version",
        name: "conversation_action_executions_attention_versions"
      )
      t.check_constraint(
        "(finalization_status = 'completed' AND delivery_finalized_at IS NOT NULL) OR " \
          "(finalization_status <> 'completed' AND delivery_finalized_at IS NULL)",
        name: "conversation_action_executions_finalization"
      )
    end

    add_reference :conversation_messages,
      :conversation_action_execution,
      foreign_key: { on_delete: :nullify },
      index: { unique: true, name: "index_action_reply_on_execution" }
    add_column :conversation_messages, :actor_snapshot, :json
    reversible do |direction|
      direction.up do
        execute "UPDATE conversation_messages SET actor_snapshot = JSON_OBJECT()"
      end
    end
    add_column :conversation_messages, :reply_scheduling_status, :string
    add_column :conversation_messages,
      :reply_scheduling_generation,
      :integer,
      null: false,
      default: 0
    add_column :conversation_messages,
      :reply_scheduling_token,
      :string,
      collation: "utf8mb4_0900_bin"
    add_column :conversation_messages, :reply_scheduling_claimed_at, :datetime
    add_column :conversation_messages,
      :reply_scheduling_attempts,
      :integer,
      null: false,
      default: 0
    add_column :conversation_messages, :next_reply_scheduling_at, :datetime
    add_column :conversation_messages, :reply_scheduled_at, :datetime
    add_column :conversation_messages, :reply_schedule_consumed_at, :datetime
    add_column :conversation_messages,
      :last_reply_scheduling_error,
      :string,
      limit: 2_000
    add_index :conversation_messages,
      %i[reply_scheduling_status next_reply_scheduling_at id],
      name: "index_action_replies_on_due_scheduling"
    add_index :conversation_messages,
      %i[reply_scheduling_status reply_scheduling_claimed_at id],
      name: "index_action_replies_on_stale_scheduling"
    add_index :conversation_messages,
      %i[
        reply_scheduling_status reply_scheduled_at
        reply_schedule_consumed_at id
      ],
      name: "index_action_replies_on_lost_scheduling"
    add_index :conversation_messages,
      %i[kind status conversation_action_execution_id id],
      name: "index_action_replies_on_finalization"
    add_check_constraint :conversation_messages,
      "reply_scheduling_status IS NULL OR " \
        "reply_scheduling_status IN ('reserved', 'claimed', 'enqueued', " \
          "'consumed', 'exhausted', 'canceled')",
      name: "conversation_messages_action_reply_scheduling"
    add_check_constraint :conversation_messages,
      "reply_scheduling_attempts >= 0 AND reply_scheduling_attempts <= 5 " \
        "AND reply_scheduling_generation >= 0",
      name: "conversation_messages_action_reply_attempts"
    add_check_constraint :conversation_messages,
      "(reply_scheduling_status = 'claimed' AND " \
        "reply_scheduling_token IS NOT NULL AND " \
        "reply_scheduling_claimed_at IS NOT NULL) OR " \
        "(reply_scheduling_status <> 'claimed' AND " \
        "reply_scheduling_token IS NULL AND " \
        "reply_scheduling_claimed_at IS NULL) OR " \
        "reply_scheduling_status IS NULL",
      name: "conversation_messages_action_reply_claim"

    add_column :conversation_actions, :decision_actor_snapshot, :json
    reversible do |direction|
      direction.up do
        execute "UPDATE conversation_actions SET decision_actor_snapshot = JSON_OBJECT()"
      end
    end

    add_column :conversation_events,
      :execution_event_key,
      :string,
      collation: "utf8mb4_0900_bin"
    add_index :conversation_events,
      :execution_event_key,
      unique: true,
      name: "index_conversation_events_on_execution_event_key"

    remove_foreign_key :conversation_actions,
      :users,
      column: :decided_by_user_id
    add_foreign_key :conversation_actions,
      :users,
      column: :decided_by_user_id,
      on_delete: :nullify
  end
end

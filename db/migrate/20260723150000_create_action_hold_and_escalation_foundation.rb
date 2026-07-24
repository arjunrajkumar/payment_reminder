class CreateActionHoldAndEscalationFoundation < ActiveRecord::Migration[8.1]
  def change
    add_column :conversation_messages,
      :provider_delivery_started_at,
      :datetime
    add_index :conversation_messages,
      %i[status provider_delivery_started_at],
      name: "index_conversation_messages_on_provider_delivery_claim"
    add_column :conversation_messages,
      :manual_reminder_delivery_job_id,
      :string,
      as: "IF(kind = 'manual_reminder', delivery_job_id, NULL)",
      stored: true,
      collation: "utf8mb4_0900_bin"
    add_index :conversation_messages,
      :manual_reminder_delivery_job_id,
      unique: true,
      name: "index_manual_reminders_on_delivery_job_id"

    add_column :invoice_reminders, :terminal_at_delivery, :boolean
    add_column :invoice_reminders,
      :notifications_initialized_at,
      :datetime
    add_column :invoice_reminders,
      :notifications_finalized_at,
      :datetime
    add_index :invoice_reminders,
      %i[notifications_finalized_at notifications_initialized_at],
      name: "index_invoice_reminders_on_notification_state"

    add_column :email_message_receipts,
      :post_processing_finalized_at,
      :datetime
    add_column :email_message_receipts,
      :post_processing_enqueued_job_id,
      :string,
      collation: "utf8mb4_0900_bin"
    add_column :email_message_receipts,
      :post_processing_enqueued_at,
      :datetime
    add_column :email_message_receipts,
      :post_processing_job_id,
      :string,
      collation: "utf8mb4_0900_bin"
    add_column :email_message_receipts,
      :post_processing_started_at,
      :datetime
    add_index :email_message_receipts,
      %i[status post_processing_finalized_at],
      name: "index_email_receipts_on_post_processing"

    create_table :invoice_reminder_notification_deliveries do |t|
      t.references :account, null: false, foreign_key: true
      t.references :invoice_reminder, null: false, foreign_key: true
      t.references :recipient_user,
        foreign_key: { to_table: :users, on_delete: :nullify }
      t.bigint :recipient_user_snapshot_id, null: false
      t.string :recipient_email, null: false
      t.string :event_name, null: false
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.integer :build_attempts, null: false, default: 0
      t.integer :scheduling_failures, null: false, default: 0
      t.string :attempt_token, collation: "utf8mb4_0900_bin"
      t.string :build_token, collation: "utf8mb4_0900_bin"
      t.datetime :build_started_at
      t.string :retry_job_id, collation: "utf8mb4_0900_bin"
      t.datetime :retry_enqueued_at
      t.datetime :next_retry_at
      t.datetime :delivery_started_at
      t.datetime :delivered_at
      t.datetime :failed_at
      t.datetime :canceled_at
      t.string :terminal_reason
      t.string :last_error_class
      t.text :last_error_message
      t.timestamps

      t.index %i[invoice_reminder_id recipient_user_snapshot_id event_name],
        unique: true,
        name: "index_reminder_notification_deliveries_on_recipient"
      t.index %i[status delivery_started_at],
        name: "index_reminder_notification_deliveries_on_status"
      t.index %i[status retry_job_id next_retry_at],
        name: "index_reminder_notification_deliveries_on_due_retry"
      t.index %i[status retry_enqueued_at retry_job_id],
        name: "index_reminder_notification_deliveries_on_stale_retry"
      t.index %i[status build_started_at build_token],
        name: "index_reminder_notification_deliveries_on_stale_build"
      t.check_constraint(
        "status IN ('pending', 'delivering', 'delivered', " \
          "'uncertain', 'failed', 'canceled')",
        name: "invoice_reminder_notification_deliveries_status"
      )
      t.check_constraint(
        "attempts >= 0 AND attempts <= 5",
        name: "invoice_reminder_notification_deliveries_attempts"
      )
      t.check_constraint(
        "build_attempts >= 0 AND build_attempts <= 5",
        name: "invoice_reminder_notification_deliveries_build_attempts"
      )
      t.check_constraint(
        "scheduling_failures >= 0",
        name: "invoice_reminder_notification_deliveries_scheduling_failures"
      )
    end

    create_table :conversation_actions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true
      t.references :source_message,
        foreign_key: { to_table: :conversation_messages, on_delete: :nullify }
      t.string :action_type, null: false
      t.string :status, null: false
      t.string :origin_kind, null: false
      t.references :created_by_user,
        foreign_key: { to_table: :users }
      t.bigint :decided_revision_id
      t.references :decided_by_user,
        foreign_key: { to_table: :users }
      t.datetime :decided_at
      t.text :decision_note
      t.string :idempotency_key, null: false
      t.string :decision_idempotency_key
      t.integer :lock_version, null: false, default: 0
      t.timestamps

      t.index %i[account_id idempotency_key],
        unique: true,
        name: "index_conversation_actions_on_account_and_idempotency"
      t.index %i[conversation_id status]
      t.index :decided_revision_id
      t.check_constraint(
        "status IN ('pending_approval', 'approved', 'rejected')",
        name: "conversation_actions_status"
      )
      t.check_constraint(
        "origin_kind IN ('user', 'system', 'ai')",
        name: "conversation_actions_origin_kind"
      )
      t.check_constraint(
        "(status = 'pending_approval' AND decided_at IS NULL " \
          "AND decision_idempotency_key IS NULL) OR " \
          "(status IN ('approved', 'rejected') AND decided_at IS NOT NULL " \
          "AND decision_idempotency_key IS NOT NULL)",
        name: "conversation_actions_decision_state"
      )
    end

    create_table :conversation_action_revisions do |t|
      t.references :conversation_action, null: false, foreign_key: true
      t.references :invoice, foreign_key: true
      t.references :customer, foreign_key: true
      t.integer :revision_number, null: false
      t.string :author_kind, null: false
      t.references :author_user,
        foreign_key: { to_table: :users }
      t.text :user_facing_summary, null: false
      t.text :rationale
      t.json :arguments, null: false
      t.json :proposed_reply, null: false
      t.string :idempotency_key, null: false
      t.timestamps

      t.index %i[conversation_action_id revision_number],
        unique: true,
        name: "index_action_revisions_on_action_and_number"
      t.index %i[conversation_action_id idempotency_key],
        unique: true,
        name: "index_action_revisions_on_action_and_idempotency"
      t.check_constraint(
        "revision_number > 0",
        name: "conversation_action_revisions_number_positive"
      )
      t.check_constraint(
        "author_kind IN ('user', 'system', 'ai')",
        name: "conversation_action_revisions_author_kind"
      )
    end

    add_foreign_key :conversation_actions,
      :conversation_action_revisions,
      column: :decided_revision_id,
      on_delete: :nullify

    create_table :collection_holds do |t|
      t.references :account, null: false, foreign_key: true
      t.references :invoice, null: false, foreign_key: true
      t.references :customer, foreign_key: true
      t.json :customer_snapshot, null: false
      t.references :conversation, null: false, foreign_key: true
      t.references :source_message,
        foreign_key: { to_table: :conversation_messages, on_delete: :nullify }
      t.references :conversation_action,
        foreign_key: { on_delete: :nullify }
      t.string :reason, null: false
      t.string :status, null: false
      t.text :note
      t.string :placed_by_kind, null: false
      t.references :placed_by_user,
        foreign_key: { to_table: :users }
      t.datetime :placed_at, null: false
      t.references :released_by_user,
        foreign_key: { to_table: :users }
      t.datetime :released_at
      t.text :release_note
      t.string :idempotency_key, null: false
      t.string :release_idempotency_key
      t.json :in_flight_delivery_message_ids, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps

      t.index %i[account_id idempotency_key],
        unique: true,
        name: "index_collection_holds_on_account_and_idempotency"
      t.index %i[invoice_id status]
      t.index %i[conversation_id status]
      t.check_constraint(
        "reason IN ('manual', 'dispute', 'other')",
        name: "collection_holds_reason"
      )
      t.check_constraint(
        "status IN ('active', 'released')",
        name: "collection_holds_status"
      )
      t.check_constraint(
        "(status = 'active' AND released_at IS NULL " \
          "AND release_idempotency_key IS NULL) OR " \
          "(status = 'released' AND released_at IS NOT NULL " \
          "AND release_idempotency_key IS NOT NULL)",
        name: "collection_holds_release_state"
      )
    end

    create_table :conversation_escalations do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true
      t.references :invoice, foreign_key: true
      t.references :customer, foreign_key: true
      t.references :source_message,
        foreign_key: { to_table: :conversation_messages, on_delete: :nullify }
      t.references :conversation_action,
        foreign_key: { on_delete: :nullify }
      t.references :collection_hold,
        foreign_key: { on_delete: :nullify }
      t.string :category, null: false
      t.string :priority, null: false
      t.string :status, null: false
      t.text :summary, null: false
      t.text :details
      t.string :opened_by_kind, null: false
      t.references :opened_by_user,
        foreign_key: { to_table: :users }
      t.datetime :opened_at, null: false
      t.datetime :last_opened_at, null: false
      t.references :resolved_by_user,
        foreign_key: { to_table: :users }
      t.datetime :resolved_at
      t.text :resolution_note
      t.string :idempotency_key, null: false
      t.string :transition_idempotency_key
      t.integer :lock_version, null: false, default: 0
      t.timestamps

      t.index %i[account_id idempotency_key],
        unique: true,
        name: "index_escalations_on_account_and_idempotency"
      t.index %i[conversation_id status]
      t.index %i[invoice_id status]
      t.check_constraint(
        "category IN ('dispute', 'low_confidence', 'ambiguous', " \
          "'delivery_failure', 'connection_failure', 'other')",
        name: "conversation_escalations_category"
      )
      t.check_constraint(
        "priority IN ('normal', 'high', 'urgent')",
        name: "conversation_escalations_priority"
      )
      t.check_constraint(
        "status IN ('open', 'resolved')",
        name: "conversation_escalations_status"
      )
      t.check_constraint(
        "(status = 'open' AND resolved_at IS NULL AND resolution_note IS NULL) OR " \
          "(status = 'resolved' AND resolved_at IS NOT NULL)",
        name: "conversation_escalations_resolution_state"
      )
    end
  end
end

class ConversationEvent < ApplicationRecord
  ACTOR_KINDS = {
    system: "system",
    user: "user",
    ai: "ai",
    customer: "customer"
  }.freeze
  KINDS = {
    conversation_created: "conversation_created",
    conversation_resolved: "conversation_resolved",
    conversation_reopened: "conversation_reopened",
    conversation_message_received: "conversation_message_received",
    conversation_message_imported: "conversation_message_imported",
    conversation_message_reviewed: "conversation_message_reviewed",
    conversation_message_review_corrected: "conversation_message_review_corrected",
    conversation_attention_cleared: "conversation_attention_cleared",
    conversation_manually_matched: "conversation_manually_matched",
    conversations_linked: "conversations_linked",
    conversation_manual_reply_queued: "conversation_manual_reply_queued",
    conversation_manual_reply_sent: "conversation_manual_reply_sent",
    conversation_manual_reply_failed: "conversation_manual_reply_failed",
    conversation_manual_reply_unconfirmed: "conversation_manual_reply_unconfirmed",
    conversation_action_created: "conversation_action_created",
    conversation_action_revised: "conversation_action_revised",
    conversation_action_approved: "conversation_action_approved",
    conversation_action_rejected: "conversation_action_rejected",
    conversation_action_execution_queued: "conversation_action_execution_queued",
    conversation_action_execution_started: "conversation_action_execution_started",
    conversation_action_effect_applied: "conversation_action_effect_applied",
    conversation_action_reply_queued: "conversation_action_reply_queued",
    conversation_action_execution_succeeded: "conversation_action_execution_succeeded",
    conversation_action_execution_failed: "conversation_action_execution_failed",
    conversation_action_execution_unconfirmed: "conversation_action_execution_unconfirmed",
    conversation_action_execution_canceled: "conversation_action_execution_canceled",
    conversation_action_execution_reconciled: "conversation_action_execution_reconciled",
    invoice_reminder_notifications_finalized: "invoice_reminder_notifications_finalized",
    collection_hold_placed: "collection_hold_placed",
    collection_hold_released: "collection_hold_released",
    conversation_escalated: "conversation_escalated",
    conversation_escalation_resolved: "conversation_escalation_resolved",
    conversation_escalation_reopened: "conversation_escalation_reopened",
    conversation_ai_analysis_queued: "conversation_ai_analysis_queued",
    conversation_ai_analysis_started: "conversation_ai_analysis_started",
    conversation_ai_analysis_completed: "conversation_ai_analysis_completed",
    conversation_ai_analysis_failed: "conversation_ai_analysis_failed",
    conversation_ai_analysis_skipped: "conversation_ai_analysis_skipped",
    conversation_ai_analysis_superseded: "conversation_ai_analysis_superseded",
    conversation_ai_plan_created: "conversation_ai_plan_created",
    conversation_ai_evaluation_recorded: "conversation_ai_evaluation_recorded",
    customer_ai_signal_proposed: "customer_ai_signal_proposed",
    customer_ai_signal_approved: "customer_ai_signal_approved",
    customer_ai_signal_rejected: "customer_ai_signal_rejected",
    customer_ai_guidance_activated: "customer_ai_guidance_activated"
  }.freeze

  belongs_to :account, inverse_of: :conversation_events
  belongs_to :conversation, inverse_of: :conversation_events
  belongs_to :conversation_message, optional: true, inverse_of: :conversation_events
  belongs_to :actor_user,
    class_name: "User",
    optional: true,
    inverse_of: :conversation_events

  enum :actor_kind, ACTOR_KINDS, prefix: true, validate: true
  enum :kind, KINDS, prefix: true, validate: true

  attribute :metadata, default: -> { {} }

  before_validation :derive_account_from_conversation

  validates :metadata, exclusion: { in: [ nil ], message: "can't be blank" }
  validates :execution_event_key, uniqueness: true, allow_nil: true
  validates :ai_event_key, uniqueness: true, allow_nil: true
  validate :account_matches_conversation
  validate :conversation_message_matches_event
  validate :actor_user_matches_event

  scope :chronological, -> { order(:created_at, :id) }

  class << self
    def record!(
      conversation:,
      kind:,
      actor_kind:,
      actor_user: nil,
      conversation_message: nil,
      metadata: {},
      created_at: Time.current
    )
      create!(
        conversation:,
        kind:,
        actor_kind:,
        actor_user:,
        conversation_message:,
        metadata:,
        created_at:
      )
    end

    def record_once!(
      conversation:,
      kind:,
      actor_kind:,
      conversation_message:,
      actor_user: nil,
      metadata: {},
      created_at: Time.current
    )
      create_or_find_by!(
        conversation_message:,
        kind:
      ) do |event|
        event.conversation = conversation
        event.actor_kind = actor_kind
        event.actor_user = actor_user
        event.metadata = metadata
        event.created_at = created_at
      end
    end

    def record_execution_once!(
      execution:,
      role:,
      kind:,
      conversation_message: nil,
      metadata: {},
      created_at: Time.current
    )
      key = [
        "execution",
        execution.id,
        role.to_s
      ].join(":")
      create_or_find_by!(execution_event_key: key) do |event|
        event.conversation = execution.conversation_action.conversation.canonical
        event.conversation_message = conversation_message
        event.kind = kind
        event.actor_kind = :system
        event.metadata = metadata.merge(
          "conversation_action_id" => execution.conversation_action_id,
          "conversation_action_execution_id" => execution.id,
          "event_role" => role.to_s
        )
        event.created_at = created_at
      end
    end

    def record_ai_once!(
      interpretation:,
      role:,
      kind:,
      actor_kind: :system,
      actor_user: nil,
      conversation_message: nil,
      metadata: {},
      created_at: Time.current
    )
      key = [ "ai", interpretation.id, role.to_s ].join(":")
      find_by(ai_event_key: key) || create!(ai_event_key: key) do |event|
        event.conversation = interpretation.conversation.canonical
        event.conversation_message = conversation_message
        event.kind = kind
        event.actor_kind = actor_kind
        event.actor_user = actor_user
        event.metadata = metadata.merge(
          "conversation_interpretation_id" => interpretation.id,
          "event_role" => role.to_s
        )
        event.created_at = created_at
      end
    rescue ActiveRecord::RecordNotUnique
      find_by!(ai_event_key: key)
    end
  end

  def readonly?
    persisted? || super
  end

  def delete
    raise ActiveRecord::ReadOnlyRecord, "Conversation events are append-only"
  end

  private
    def derive_account_from_conversation
      self.account = conversation.account if conversation.present?
    end

    def account_matches_conversation
      return if account.blank? || conversation.blank? || account == conversation.account

      errors.add(:account, "must match conversation account")
    end

    def conversation_message_matches_event
      return if conversation_message.blank? || account.blank? || conversation.blank?
      return if conversation_message.account == account &&
        Conversations::ReviewWorkUnit.includes_message?(
          conversation: conversation.canonical,
          message: conversation_message
        )

      errors.add(:conversation_message, "must belong to the same account and conversation")
    end

    def actor_user_matches_event
      if actor_user.present? && account.present? && actor_user.account != account
        errors.add(:actor_user, "must belong to the conversation account")
      end

      if actor_kind_user?
        errors.add(:actor_user, "must be present for a user event") if actor_user.blank?
      elsif actor_user.present?
        message = if actor_kind_customer?
          "must be blank unless this is a user event"
        else
          "must be blank for a system or AI event"
        end
        errors.add(:actor_user, message)
      end
    end
end

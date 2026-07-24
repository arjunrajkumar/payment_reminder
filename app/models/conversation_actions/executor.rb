class ConversationActions::Executor
  RETRY_DELAY = 5.minutes

  def self.call(execution:, at: Time.current)
    new(execution:, at:).call
  end

  def self.fail_exhausted!(execution, at: Time.current)
    new(execution:, at:).send(
      :fail_pending!,
      category: "execution_retries_exhausted",
      reason:
        "The approved command could not be executed safely after retrying."
    )
  end

  def self.fail_scheduling_exhausted!(execution, at: Time.current)
    new(execution:, at:).send(
      :fail_pending!,
      category: "execution_scheduling_exhausted",
      reason:
        "The approved command could not be scheduled after retrying."
    )
  end

  def initialize(execution:, at:)
    @execution = execution
    @at = at
  end

  def call
    @claim = execution.claim_phase!(
      expected_phase: execution.reload.phase,
      at:
    )
    return execution unless claim

    case claim.phase
    when "effect"
      execute_effect_phase
    when "reply_reservation"
      execute_reply_reservation_phase
    end
    execution.reload
  rescue ConversationActionExecution::ClaimLost
    execution.reload
  rescue InvoiceSources::ProviderError,
    InvoiceReminders::InvoiceFreshnessCheck::Error
    release_for_retry!(
      category: "provider_refresh_temporary",
      reason: "Invoice provider refresh is temporarily unavailable."
    )
    execution.reload
  rescue Receivables::AccountLock::Unavailable,
    ActiveRecord::Deadlocked,
    ActiveRecord::LockWaitTimeout
    release_for_retry!(
      category: "workflow_lock_temporary",
      reason: "The work item is temporarily busy."
    )
    execution.reload
  rescue ConversationActions::Commands::Unauthorized => error
    cancel_execution!(error.message)
  rescue ConversationActions::Error,
    ConversationMessages::ManualReply::Error,
    ActiveRecord::RecordInvalid,
    ActiveRecord::RecordNotFound => error
    fail_owned!(
      category: safe_failure_category(error),
      reason: safe_failure_reason(error)
    )
  end

  private
    attr_reader :execution, :claim, :at

    def execute_effect_phase
      action = execution.conversation_action
      revision = execution.conversation_action_revision
      definition = ConversationActions::Catalog.validate!(
        action_type: action.action_type,
        arguments: revision.arguments,
        proposed_reply: revision.proposed_reply
      )
      refreshed_invoice = refresh_invoice(revision.invoice) if
        definition.provider_refresh_required
      reply_required = false

      Conversations::ReviewWorkUnit.with_reconciled_workflow_owner(
        conversation: action.conversation,
        at:
      ) do |conversation, work_unit|
        source_message = lock_source_message(action, work_unit:)
        invoice = lock_and_validate_invoice!(
          revision:,
          definition:,
          refreshed_invoice:
        )
        approver = execution.account.users.lock.find_by(
          id: execution.approved_by_user_id
        )
        locked_action = execution.account.conversation_actions.lock
          .find(action.id)
        locked_revision = locked_action.revisions.lock.find(revision.id)
        execution.lock!
        execution.verify_claim!(claim, expected_phase: :effect)
        validate_execution_context!(
          action: locked_action,
          revision: locked_revision,
          definition:,
          conversation:,
          invoice:,
          source_message:,
          approver:
        )
        record_started_event!

        result = ConversationActions::Commands::Dispatcher.call(
          execution:,
          action: locked_action,
          revision: locked_revision,
          definition:,
          conversation:,
          invoice:,
          source_message:,
          at:
        )
        reply_required = result.rendered_reply.present?
        transition_effect_result!(
          action: locked_action,
          definition:,
          result:
        )
        Conversations::Attention.recompute!(
          conversation:,
          at:
        )
      end

      ConversationActions::ExecutionRequest.enqueue(
        execution.reload,
        at:
      ) if reply_required
      continue_reply_reservation_inline if reply_required
    end

    def execute_reply_reservation_phase
      message = nil
      action = execution.conversation_action
      revision = execution.conversation_action_revision
      definition = ConversationActions::Catalog.validate!(
        action_type: action.action_type,
        arguments: revision.arguments,
        proposed_reply: revision.proposed_reply
      )

      Conversations::ReviewWorkUnit.with_reconciled_workflow_owner(
        conversation: action.conversation,
        at:
      ) do |conversation, work_unit|
        source_message = lock_source_message(action, work_unit:)
        approver = execution.account.users.lock.find_by(
          id: execution.approved_by_user_id
        )
        locked_action = execution.account.conversation_actions.lock
          .find(action.id)
        locked_revision = locked_action.revisions.lock.find(revision.id)
        execution.lock!
        execution.verify_claim!(claim, expected_phase: :reply_reservation)
        validate_execution_context!(
          action: locked_action,
          revision: locked_revision,
          definition:,
          conversation:,
          invoice: revision.invoice,
          source_message:,
          approver:
        )
        record_started_event!
        rendered = ConversationActions::ReplyRenderer::Rendered.new(
          subject: execution.reply_snapshot.fetch("subject"),
          body: execution.reply_snapshot.fetch("body")
        )
        message = ConversationMessages::ActionReply.reserve!(
          execution:,
          conversation:,
          reply_to_message: source_message,
          kind: execution.reply_snapshot.fetch("kind"),
          rendered_reply: rendered,
          cc_addresses: execution.reply_snapshot.fetch("cc_addresses", []),
          at:
        )
        execution.transition_from_claim!(
          claim,
          to_status: :awaiting_delivery,
          to_phase: :delivery,
          finalization_status: :pending,
          scheduling_status: :canceled,
          scheduling_token: nil,
          scheduling_claimed_at: nil,
          result_metadata: execution.result_metadata.merge(
            "conversation_message_id" => message.id
          )
        )
      end

      ConversationMessages::ActionReplyRequest.enqueue(message, at:)
    end

    def continue_reply_reservation_inline
      @claim = execution.reload.claim_phase!(
        expected_phase: :reply_reservation,
        at:
      )
      execute_reply_reservation_phase if claim
    end

    def transition_effect_result!(action:, definition:, result:)
      effect_at = result.effect_mutated ? at : nil
      event_metadata = {
        "result_code" => result.result_code,
        "outcome" => result.result_metadata["outcome"],
        "payment_promise_id" => result.payment_promise&.id,
        "customer_email_address_id" => result.customer_email_address&.id,
        "collection_hold_id" => result.collection_hold&.id,
        "effect_escalation_id" => result.effect_escalation&.id,
        "effect_mutated" => result.effect_mutated
      }.compact
      ConversationEvent.record_execution_once!(
        execution:,
        role: "effect:#{claim.generation}",
        kind: :conversation_action_effect_applied,
        metadata: event_metadata,
        created_at: at
      )

      common = {
        effect_completed_at: at,
        effect_applied_at: effect_at,
        payment_promise: result.payment_promise,
        customer_email_address: result.customer_email_address,
        collection_hold: result.collection_hold,
        effect_escalation: result.effect_escalation,
        attention_required: result.attention_required,
        attention_version: result.attention_required ?
          execution.attention_version + 1 :
          execution.attention_version,
        result_code: result.result_code,
        result_metadata: result.result_metadata,
        reply_snapshot: reply_snapshot_for(definition:, result:)
      }

      if result.rendered_reply
        execution.transition_from_claim!(
          claim,
          to_status: :pending,
          to_phase: :reply_reservation,
          **common,
          attempts: 0,
          scheduling_status: :reserved,
          scheduling_attempts: 0,
          scheduling_token: nil,
          scheduling_claimed_at: nil,
          next_scheduling_at: at,
          scheduled_at: nil,
          schedule_consumed_at: nil
        )
      else
        execution.transition_from_claim!(
          claim,
          to_status: :succeeded,
          to_phase: :finalized,
          **common,
          finished_at: at,
          finalization_status: :not_required,
          scheduling_status: :canceled,
          scheduling_token: nil,
          scheduling_claimed_at: nil
        )
        ConversationEvent.record_execution_once!(
          execution:,
          role: "terminal:succeeded",
          kind: :conversation_action_execution_succeeded,
          metadata: {
            "result_code" => result.result_code,
            "attention_required" => result.attention_required
          },
          created_at: at
        )
      end
    end

    def reply_snapshot_for(definition:, result:)
      return {} unless result.rendered_reply

      {
        "kind" => definition.reply_kind.to_s,
        "subject" => result.rendered_reply.subject,
        "body" => result.rendered_reply.body,
        "cc_addresses" => result.cc_addresses
      }
    end

    def refresh_invoice(invoice)
      raise ConversationActions::Commands::Stale,
        "The approved invoice is no longer available." unless invoice
      connection = ActiveRecord::Base.connection
      if connection.transaction_open? &&
          connection.current_transaction.joinable?
        raise ConversationActions::Commands::Unsafe,
          "Invoice refresh cannot run inside a database transaction."
      end

      InvoiceReminders::InvoiceFreshnessCheck.call(invoice)
    end

    def lock_and_validate_invoice!(revision:, definition:, refreshed_invoice:)
      return nil unless definition.invoice_required
      invoice_id = revision.invoice_id ||
        raise(ConversationActions::Commands::Stale,
          "The approved invoice is no longer available.")
      invoice = execution.account.invoices.lock.find(invoice_id)
      if refreshed_invoice &&
          (
            refreshed_invoice.id != invoice.id ||
            invoice.synced_at.blank? ||
            invoice.synced_at < refreshed_invoice.synced_at
          )
        raise ConversationActions::Commands::Stale,
          "The refreshed invoice state changed unexpectedly."
      end
      invoice
    end

    def lock_source_message(action, work_unit:)
      return unless action.source_message_id

      message = execution.account.conversation_messages.lock
        .find(action.source_message_id)
      unless work_unit.message_ids.include?(message.id)
        raise ConversationActions::Commands::Stale,
          "The source email no longer belongs to this work item."
      end
      message
    end

    def validate_execution_context!(
      action:,
      revision:,
      definition:,
      conversation:,
      invoice:,
      source_message:,
      approver:
    )
      unless action.status_approved? &&
          action.decided_revision_id == revision.id &&
          execution.conversation_action_revision_id == revision.id &&
          action.conversation_id == conversation.id
        raise ConversationActions::Commands::Stale,
          "The approved action no longer matches the current work item."
      end
      if definition.invoice_required &&
          (
            revision.invoice_id != invoice&.id ||
            revision.customer_id != invoice&.customer_id ||
            conversation.invoice_id != invoice&.id ||
            conversation.customer_id != invoice&.customer_id
          )
        raise ConversationActions::Commands::Stale,
          "The invoice or customer ownership changed after approval."
      end
      if definition.customer_required && revision.customer_id.blank?
        raise ConversationActions::Commands::Stale,
          "The approved customer is no longer available."
      end
      if definition.source_message_required && source_message.blank?
        raise ConversationActions::Commands::Stale,
          "A safe received customer email is required."
      end

      validate_approver!(definition, approver:)
      if invoice&.collection_held? && !definition.allowed_during_hold
        raise ConversationActions::Commands::Unsafe,
          "This action is not allowed while collection is paused."
      end
    end

    def validate_approver!(definition, approver:)
      unless approver&.active? && approver.account_id == execution.account_id
        raise ConversationActions::Commands::Unauthorized,
          "The approving user is no longer active."
      end
      authorization = if definition.action_type == "add_recipient" &&
          definition.arguments.fetch("mode") == "future_reminders"
        :admin
      else
        definition.authorization
      end
      allowed = authorization == :admin ? approver.admin? :
        approver.role.in?(%w[owner admin member])
      unless allowed
        raise ConversationActions::Commands::Unauthorized,
          "The approving user is not authorized for this command."
      end
    end

    def record_started_event!
      ConversationEvent.record_execution_once!(
        execution:,
        role: "started:#{claim.phase}:#{claim.generation}",
        kind: :conversation_action_execution_started,
        metadata: {
          "attempt" => claim.attempt,
          "phase" => claim.phase,
          "claim_generation" => claim.generation
        },
        created_at: at
      )
    end

    def release_for_retry!(category:, reason:)
      return unless claim

      execution.release_claim!(
        claim,
        next_retry_at: at + RETRY_DELAY,
        failure_category: category,
        failure_reason: reason
      )
    end

    def cancel_execution!(reason)
      return execution unless claim

      with_locked_execution do
        execution.verify_claim!(claim)
        execution.transition_from_claim!(
          claim,
          to_status: :canceled,
          to_phase: :finalized,
          finished_at: at,
          attention_required: false,
          failure_category: "authorization_changed",
          failure_reason: reason,
          result_code: "execution_canceled",
          scheduling_status: :canceled,
          finalization_status: :not_required
        )
        ConversationEvent.record_execution_once!(
          execution:,
          role: "terminal:canceled",
          kind: :conversation_action_execution_canceled,
          metadata: { "failure_category" => "authorization_changed" },
          created_at: at
        )
        recompute_attention
      end
      execution
    rescue ConversationActionExecution::ClaimLost
      execution.reload
    end

    def fail_owned!(category:, reason:)
      return execution unless claim

      with_locked_execution do
        execution.verify_claim!(claim)
        escalation = open_failure_escalation!(category:, reason:)
        execution.transition_from_claim!(
          claim,
          to_status: :failed,
          to_phase: :finalized,
          finished_at: at,
          attention_required: true,
          attention_version: execution.attention_version + 1,
          failure_category: category,
          failure_reason: reason,
          result_code: "human_attention_required",
          delivery_escalation: escalation,
          scheduling_status: :canceled,
          finalization_status: :not_required
        )
        ConversationEvent.record_execution_once!(
          execution:,
          role: "terminal:failed:#{category}",
          kind: :conversation_action_execution_failed,
          metadata: {
            "failure_category" => category,
            "conversation_escalation_id" => escalation.id
          },
          created_at: at
        )
        recompute_attention
      end
      execution
    rescue ConversationActionExecution::ClaimLost
      execution.reload
    end

    def fail_pending!(category:, reason:)
      escalation = nil
      changed = false
      with_locked_execution do
        next unless execution.status_pending?

        escalation = open_failure_escalation!(category:, reason:)
        changed = execution.fail_pending!(
          at:,
          attention_required: true,
          attention_version: execution.attention_version + 1,
          failure_category: category,
          failure_reason: reason,
          result_code: "human_attention_required",
          delivery_escalation: escalation,
          finalization_status: :not_required
        )
        if changed
          ConversationEvent.record_execution_once!(
            execution:,
            role: "terminal:failed:#{category}",
            kind: :conversation_action_execution_failed,
            metadata: {
              "failure_category" => category,
              "conversation_escalation_id" => escalation.id
            },
            created_at: at
          )
          recompute_attention
        end
      end
      execution.reload
    end

    def with_locked_execution(&)
      action = execution.conversation_action
      Conversations::ReviewWorkUnit.with_reconciled_workflow_owner(
        conversation: action.conversation,
        at:
      ) do
        execution.account.conversation_actions.lock.find(action.id)
        execution.lock!
        yield
      end
    end

    def open_failure_escalation!(category:, reason:)
      ConversationEscalations::Opening.call(
        conversation: execution.conversation_action.conversation,
        category: :other,
        priority: :high,
        summary: "An approved action requires human attention.",
        details: reason,
        source_message: execution.conversation_action.source_message,
        conversation_action: execution.conversation_action,
        opened_by_kind: :system,
        idempotency_key:
          "action-execution:#{execution.id}:failure:#{category}",
        at:
      )
    end

    def safe_failure_category(error)
      case error
      when ConversationActions::Catalog::InvalidAction
        "invalid_action"
      when ConversationActions::Commands::Stale,
        ActiveRecord::RecordNotFound,
        ConversationMessages::ManualReply::StaleComposer
        "stale_action"
      when ConversationActions::ReplyRenderer::Unanswerable
        "fact_unavailable"
      when ConversationMessages::ManualReply::DeliveryUnavailable
        "delivery_unavailable"
      else
        "unsafe_action"
      end
    end

    def safe_failure_reason(error)
      if error.is_a?(ActiveRecord::RecordInvalid)
        return error.record.errors.full_messages.join(", ").first(2_000)
      end
      allowed = [
        ConversationActions::Error,
        ConversationMessages::ManualReply::Error
      ]
      allowed.any? { |type| error.is_a?(type) } ?
        error.message.to_s.first(2_000) :
        "The approved action could not be executed safely."
    end

    def recompute_attention
      Conversations::Attention.recompute!(
        conversation: execution.conversation_action.conversation,
        at:
      )
    end
end

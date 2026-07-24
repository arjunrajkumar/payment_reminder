class ConversationAi::AnalysisRequest
  class SchedulingError < StandardError; end

  class << self
    def enqueue_for(message, requested_by: nil, reanalysis: false)
      new(message:, requested_by:, reanalysis:).enqueue
    end

    def schedule(interpretation)
      new(message: interpretation.source_message).schedule(interpretation)
    end
  end

  def initialize(message:, requested_by: nil, reanalysis: false)
    @message = message
    @requested_by = requested_by
    @reanalysis = reanalysis
  end

  def enqueue
    decision = ConversationAi::Eligibility.decision(
      message,
      explicit: reanalysis
    )
    return nil unless decision.eligible?

    configuration = ConversationAi::Configuration.for(account: message.account)
    return nil unless configuration.available?

    owner = decision.owner
    guidance_revision = owner.customer&.customer_ai_profile&.active_guidance_revision
    generation = reanalysis ? next_reanalysis_generation : 1
    analysis_key = ConversationAi::Eligibility.analysis_key(
      message:,
      configuration:,
      guidance_revision:,
      generation:
    )
    scope = message.account.conversation_interpretations
    interpretation = scope.find_by(analysis_key:) ||
      scope.create!(analysis_key:) do |record|
        record.conversation = owner
        record.source_message = message
        record.invoice = owner.invoice
        record.customer = owner.customer
        record.supersedes_interpretation = latest_interpretation if reanalysis
        record.customer_ai_guidance_revision = guidance_revision
        record.requested_mode = :shadow
        record.status = :pending
        record.context_snapshot = {}
        record.authored_content_warnings = []
        record.source_identity_snapshot = source_identity_snapshot
        record.semantic_prompt_version =
          ConversationAi::Prompts::ClassifierV1::PROMPT_VERSION
        record.provider_adapter_version =
          ConversationAi::ProviderRegistry.fetch(configuration.provider)::ADAPTER_VERSION
        record.result_schema_version = ConversationAi::OutputSchema::VERSION
        record.planner_version = ConversationAi::Planner::VERSION
        record.catalog_version =
          ConversationActions::Catalog::TEMPLATE_VERSION.to_s
        record.provider = configuration.provider
        record.requested_model = configuration.model
        record.scheduling_status = :reserved
        record.reason_codes = []
        record.structured_result = {}
      end
    return interpretation if interpretation.finalized_at?

    snapshot_context!(interpretation, owner, guidance_revision)
    if decision.local_decision
      finalize_local!(interpretation, decision)
    else
      schedule(interpretation)
    end
    interpretation
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => error
    raise if error.is_a?(ActiveRecord::RecordInvalid) &&
      !error.record.errors.of_kind?(:analysis_key, :taken)

    retry
  end

  def schedule(interpretation)
    claim = reserve_scheduling!(interpretation)
    return false unless claim

    job = ConversationAi::AnalyzeJob.perform_later(
      interpretation.id,
      claim.fetch(:generation)
    )
    unless job
      release_failed_scheduling!(interpretation, claim, "enqueue returned false")
      return false
    end
    accepted = ConversationInterpretation.where(
      id: interpretation.id,
      scheduling_status: :claimed,
      scheduling_generation: claim.fetch(:generation),
      scheduling_token: claim.fetch(:token)
    ).update_all(
      scheduling_status: ConversationInterpretation
        .scheduling_statuses.fetch(:enqueued),
      scheduling_token: nil,
      scheduling_claimed_at: nil,
      scheduling_enqueued_at: Time.current,
      last_scheduling_error: nil,
      updated_at: Time.current
    )
    raise SchedulingError, "Scheduling ownership was lost." unless accepted == 1

    ConversationEvent.record_ai_once!(
      interpretation:,
      role: "queued:#{claim.fetch(:generation)}",
      kind: :conversation_ai_analysis_queued,
      metadata: {
        "provider" => interpretation.provider,
        "requested_model" => interpretation.requested_model
      }
    )
    true
  rescue StandardError => error
    release_failed_scheduling!(interpretation, claim, error.class.name) if claim
    false
  end

  private
    attr_reader :message, :requested_by, :reanalysis

    def snapshot_context!(interpretation, owner, guidance_revision)
      Conversations::ReviewWorkUnit.with_reconciled_workflow_owner(
        conversation: owner
      ) do |locked_owner, work_unit|
        context = ConversationAi::ContextBuilder.build(
          message:,
          work_unit:,
          guidance_revision:
        )
        interpretation.with_lock do
          next if interpretation.input_digest.present?

          interpretation.update!(
            conversation: locked_owner,
            invoice: locked_owner.invoice,
            customer: locked_owner.customer,
            input_digest: context.input_digest,
            context_snapshot: context.snapshot,
            authored_content_snapshot: context.authored_content.body,
            authored_content_warnings: context.warnings
          )
        end
      end
    end

    def finalize_local!(interpretation, decision)
      now = Time.current
      result = {
        "schema_version" => ConversationAi::OutputSchema::VERSION,
        "message_kind" => decision.local_decision == "no_action" ?
          "automatic_reply" :
          "ambiguous",
        "language" => "und",
        "overall_confidence_bps" => 10_000,
        "requires_human" => decision.local_decision == "human_review",
        "summary" => decision.reason.humanize,
        "concise_rationale" => "Deterministic eligibility policy skipped the provider call.",
        "reason_codes" => [ decision.reason ],
        "intents" => [],
        "proposed_reply" => {
          "greeting" => nil,
          "acknowledgement" => nil,
          "closing" => nil,
          "tone_hints" => [],
          "outline" => []
        },
        "feedback_signals" => []
      }
      Conversations::ReviewWorkUnit.with_reconciled_workflow_owner(
        conversation: interpretation.conversation
      ) do |owner, work_unit|
        locked = interpretation.account.conversation_interpretations
          .lock
          .find(interpretation.id)
        next locked if locked.finalized_at?

        locked.update!(
          conversation: owner,
          invoice: owner.invoice,
          customer: owner.customer,
          status: :skipped,
          scheduling_status: :canceled,
          message_kind: result["message_kind"],
          language: result["language"],
          overall_confidence_bps: result["overall_confidence_bps"],
          requires_human: result["requires_human"],
          summary: result["summary"],
          concise_rationale: result["concise_rationale"],
          reason_codes: result["reason_codes"],
          structured_result: result,
          completed_at: now
        )
        plan = ConversationAi::Planner.plan(locked)
        persist_plan!(locked, plan)
        ConversationAi::Superseder.supersede_older!(
          current: locked,
          work_unit:,
          at: now
        )
        locked.update_column(:finalized_at, now)
        ConversationEvent.record_ai_once!(
          interpretation: locked,
          role: "skipped",
          kind: :conversation_ai_analysis_skipped,
          metadata: { "reason" => decision.reason }
        )
        locked
      end
    end

    def persist_plan!(interpretation, result)
      interpretation.create_conversation_ai_plan!(
        account: interpretation.account,
        decision: result.decision,
        proposed_action_type: result.proposed_action_type,
        arguments: result.arguments,
        proposed_reply: result.proposed_reply,
        user_facing_summary: result.user_facing_summary,
        planner_reason_codes: result.planner_reason_codes,
        confidence_bps: result.confidence_bps,
        planner_version: ConversationAi::Planner::VERSION,
        catalog_version: ConversationActions::Catalog::TEMPLATE_VERSION.to_s,
        status: :current
      )
    end

    def reserve_scheduling!(interpretation)
      interpretation.with_lock do
        return unless interpretation.status_pending?
        return unless interpretation.scheduling_reserved?
        if interpretation.scheduling_attempts >=
            ConversationInterpretation::MAXIMUM_SCHEDULING_ATTEMPTS
          interpretation.update!(
            status: :failed,
            scheduling_status: :exhausted,
            failure_category: "scheduling_exhausted",
            failure_reason: "The analysis could not be scheduled.",
            completed_at: Time.current
          )
          return
        end

        token = SecureRandom.hex(32)
        generation = interpretation.scheduling_generation + 1
        interpretation.update!(
          scheduling_status: :claimed,
          scheduling_attempts: interpretation.scheduling_attempts + 1,
          scheduling_generation: generation,
          scheduling_token: token,
          scheduling_claimed_at: Time.current
        )
        { token:, generation: }
      end
    end

    def release_failed_scheduling!(interpretation, claim, message)
      relation = ConversationInterpretation.where(
        id: interpretation.id,
        scheduling_status: :claimed,
        scheduling_generation: claim.fetch(:generation),
        scheduling_token: claim.fetch(:token)
      )
      attempts = interpretation.reload.scheduling_attempts
      exhausted = attempts >= ConversationInterpretation::MAXIMUM_SCHEDULING_ATTEMPTS
      relation.update_all(
        status: exhausted ?
          ConversationInterpretation.statuses.fetch(:failed) :
          ConversationInterpretation.statuses.fetch(:pending),
        scheduling_status: ConversationInterpretation.scheduling_statuses.fetch(
          exhausted ? :exhausted : :reserved
        ),
        scheduling_token: nil,
        scheduling_claimed_at: nil,
        next_scheduling_at: exhausted ? nil : Time.current + attempts.minutes,
        last_scheduling_error: message.to_s.first(2_000),
        completed_at: exhausted ? Time.current : nil,
        failure_category: exhausted ? "scheduling_exhausted" : nil,
        failure_reason: exhausted ? "The analysis could not be scheduled." : nil,
        updated_at: Time.current
      )
    end

    def latest_interpretation
      message.conversation_interpretations.order(created_at: :desc, id: :desc).first
    end

    def next_reanalysis_generation
      message.conversation_interpretations.count + 1
    end

    def source_identity_snapshot
      {
        "message_id" => message.id,
        "provider_account_id" => message.provider_account_id,
        "provider_message_id" => message.provider_message_id,
        "provider_thread_id" => message.provider_thread_id,
        "internet_message_id" => message.internet_message_id,
        "email_connection_generation" => message.email_connection_generation,
        "invoice_id" => message.invoice_id,
        "invoice_number" => message.invoice&.number,
        "customer_id" => message.conversation.customer_id,
        "customer_name" => message.conversation.customer&.name,
        "source_subject" => message.subject.to_s.first(500),
        "source_from_address" => message.from_address,
        "requested_by_user_id" => requested_by&.id
      }.compact
    end
end

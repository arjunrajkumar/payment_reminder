class ConversationAi::Analyzer
  Claim = Data.define(:token, :generation, :attempt, :invocation)

  class << self
    def call(interpretation_id:, scheduling_generation:, client: nil)
      new(
        interpretation_id:,
        scheduling_generation:,
        client:
      ).call
    end
  end

  def initialize(interpretation_id:, scheduling_generation:, client:)
    @interpretation_id = interpretation_id
    @scheduling_generation = scheduling_generation
    @client = client
  end

  def call
    interpretation = ConversationInterpretation.find(interpretation_id)
    claim = claim!(interpretation)
    return interpretation unless claim

    request = ConversationAi::Prompts::ClassifierV1.request_for(
      context: interpretation.context_snapshot,
      application_request_id: claim.invocation.application_request_id
    )
    result = provider_client(interpretation).analyze(request:)
    finalize_success!(interpretation, claim, result)
  rescue ConversationAi::ProviderError => error
    finalize_failure!(interpretation, claim, error) if interpretation && claim
  rescue ConversationAi::OutputSchema::InvalidResult => error
    provider_error = ConversationAi::ProviderError.new(
      category: "malformed_output",
      message: error.message,
      sanitized_request: result&.sanitized_request || {},
      sanitized_response: result&.sanitized_response || {},
      returned_model: result&.returned_model,
      provider_request_id: result&.provider_request_id,
      provider_metadata: result&.provider_metadata || {}
    )
    finalize_failure!(interpretation, claim, provider_error) if interpretation && claim
  end

  private
    attr_reader :interpretation_id, :scheduling_generation, :client

    def claim!(interpretation)
      interpretation.with_lock do
        return unless interpretation.status_pending?
        return unless interpretation.scheduling_enqueued?
        return unless interpretation.scheduling_generation == scheduling_generation
        unless bound_configuration_current?(interpretation)
          cancel!(interpretation, "configuration_changed")
          return
        end

        token = SecureRandom.hex(32)
        generation = interpretation.claim_generation + 1
        attempt = interpretation.provider_attempts + 1
        interpretation.update!(
          status: :running,
          scheduling_status: :consumed,
          scheduling_consumed_at: Time.current,
          provider_attempts: attempt,
          claim_generation: generation,
          claim_token: token,
          claimed_at: Time.current,
          started_at: interpretation.started_at || Time.current,
          next_retry_at: nil
        )
        invocation = interpretation.conversation_ai_invocations.create!(
          account: interpretation.account,
          attempt_number: attempt,
          claim_generation: generation,
          attempt_token: token,
          provider: interpretation.provider,
          endpoint: provider_adapter(interpretation)::ENDPOINT,
          api_version: provider_adapter(interpretation)::API_VERSION,
          provider_adapter_version: interpretation.provider_adapter_version,
          requested_model: interpretation.requested_model,
          application_request_id: SecureRandom.uuid,
          status: :started,
          sanitized_request: semantic_request_snapshot(interpretation),
          sanitized_response: {},
          provider_metadata: {},
          started_at: Time.current
        )
        ConversationEvent.record_ai_once!(
          interpretation:,
          role: "started:#{attempt}",
          kind: :conversation_ai_analysis_started,
          metadata: {
            "attempt" => attempt,
            "claim_generation" => generation,
            "provider" => interpretation.provider
          }
        )
        Claim.new(token:, generation:, attempt:, invocation:)
      end
    end

    def finalize_success!(interpretation, claim, result)
      validated = ConversationAi::OutputSchema.validate_provider_result!(
        result.structured_output.deep_stringify_keys,
        context: interpretation.context_snapshot
      )
      unless result.provider == interpretation.provider &&
          result.requested_model == interpretation.requested_model &&
          result.returned_model == interpretation.requested_model
        raise ConversationAi::ProviderError.new(
          category: "unsupported_model",
          message: "Provider returned an unexpected model.",
          provider_request_id: result.provider_request_id,
          sanitized_request: result.sanitized_request,
          sanitized_response: result.sanitized_response,
          returned_model: result.returned_model,
          provider_metadata: result.provider_metadata
        )
      end

      Conversations::ReviewWorkUnit.with_reconciled_workflow_owner(
        conversation: interpretation.conversation
      ) do |owner, work_unit|
        locked = interpretation.account.conversation_interpretations
          .lock
          .find(interpretation.id)
        invocation = locked.conversation_ai_invocations.lock.find(claim.invocation.id)
        unless current_claim?(locked, claim)
          supersede_invocation!(invocation, result)
          next locked
        end
        unless bound_configuration_current?(locked)
          supersede_invocation!(invocation, result)
          cancel!(locked, "mode_or_provider_changed")
          next locked
        end

        now = Time.current
        stale = stale_source?(locked, work_unit)
        locked.update!(
          conversation: owner,
          invoice: owner.invoice,
          customer: owner.customer,
          status: stale ? :superseded : :succeeded,
          claim_token: nil,
          claimed_at: nil,
          accepted_model: result.returned_model,
          message_kind: validated.fetch("message_kind"),
          language: validated.fetch("language"),
          overall_confidence_bps: validated.fetch("overall_confidence_bps"),
          requires_human: validated.fetch("requires_human"),
          summary: validated.fetch("summary"),
          concise_rationale: validated.fetch("concise_rationale"),
          reason_codes: validated.fetch("reason_codes"),
          structured_result: validated,
          completed_at: now,
          superseded_at: stale ? now : nil
        )
        finish_invocation!(invocation, result)
        plan_result = ConversationAi::Planner.plan(locked)
        plan = locked.create_conversation_ai_plan!(
          account: locked.account,
          decision: plan_result.decision,
          proposed_action_type: plan_result.proposed_action_type,
          arguments: plan_result.arguments,
          proposed_reply: plan_result.proposed_reply,
          user_facing_summary: plan_result.user_facing_summary,
          planner_reason_codes: plan_result.planner_reason_codes,
          confidence_bps: plan_result.confidence_bps,
          planner_version: ConversationAi::Planner::VERSION,
          catalog_version: ConversationActions::Catalog::TEMPLATE_VERSION.to_s,
          status: stale ? :superseded : :current,
          superseded_at: stale ? now : nil
        )
        CustomerAi::SignalRecorder.record!(locked) unless stale
        ConversationAi::Superseder.supersede_older!(
          current: locked,
          work_unit:,
          at: now
        ) unless stale
        locked.update_column(:finalized_at, now)
        ConversationEvent.record_ai_once!(
          interpretation: locked,
          role: stale ? "superseded" : "completed",
          kind: stale ?
            :conversation_ai_analysis_superseded :
            :conversation_ai_analysis_completed,
          metadata: {
            "conversation_ai_plan_id" => plan.id,
            "decision" => plan.decision,
            "provider" => locked.provider,
            "returned_model" => locked.accepted_model
          }
        )
        ConversationEvent.record_ai_once!(
          interpretation: locked,
          role: "plan",
          kind: :conversation_ai_plan_created,
          metadata: {
            "conversation_ai_plan_id" => plan.id,
            "decision" => plan.decision
          }
        )
        locked
      end
    rescue Conversations::ReviewWorkUnit::SplitInvoiceWorkUnit => error
      finalize_failure!(
        interpretation,
        claim,
        ConversationAi::ProviderError.new(
          category: "malformed_output",
          message: error.message,
          sanitized_request: result.sanitized_request,
          sanitized_response: result.sanitized_response,
          returned_model: result.returned_model,
          provider_request_id: result.provider_request_id
        )
      )
    end

    def finalize_failure!(interpretation, claim, error)
      should_schedule = false
      interpretation.with_lock do
        invocation = interpretation.conversation_ai_invocations.lock.find(claim.invocation.id)
        unless current_claim?(interpretation, claim)
          finish_failed_invocation!(invocation, error, status: :superseded)
          return interpretation
        end
        if !bound_configuration_current?(interpretation)
          finish_failed_invocation!(invocation, error, status: :superseded)
          cancel!(interpretation, "mode_or_provider_changed")
          return interpretation
        end

        finish_failed_invocation!(invocation, error)
        retryable = error.retryable? &&
          interpretation.provider_attempts < ConversationInterpretation::MAXIMUM_ATTEMPTS
        if retryable
          retry_at = Time.current + retry_delay(
            interpretation.provider_attempts,
            error.retry_after_seconds
          )
          interpretation.update!(
            status: :pending,
            scheduling_status: :reserved,
            scheduling_enqueued_at: nil,
            scheduling_consumed_at: nil,
            next_scheduling_at: retry_at,
            next_retry_at: retry_at,
            claim_token: nil,
            claimed_at: nil,
            failure_category: error.category,
            failure_reason: error.message
          )
          should_schedule = retry_at <= Time.current
        else
          interpretation.update!(
            status: :failed,
            claim_token: nil,
            claimed_at: nil,
            failure_category: error.category,
            failure_reason: error.message,
            completed_at: Time.current
          )
          ConversationEvent.record_ai_once!(
            interpretation:,
            role: "failed",
            kind: :conversation_ai_analysis_failed,
            metadata: {
              "failure_category" => error.category,
              "attempts" => interpretation.provider_attempts
            }
          )
        end
      end
      ConversationAi::AnalysisRequest.schedule(interpretation) if should_schedule
      interpretation
    end

    def finish_invocation!(invocation, result)
      invocation.update!(
        status: :succeeded,
        returned_model: result.returned_model,
        provider_request_id: result.provider_request_id,
        sanitized_request: result.sanitized_request,
        sanitized_response: result.sanitized_response,
        input_tokens: result.input_tokens,
        cached_input_tokens: result.cached_input_tokens,
        output_tokens: result.output_tokens,
        total_tokens: result.total_tokens,
        latency_ms: result.latency_ms,
        provider_metadata: result.provider_metadata,
        finished_at: Time.current
      )
    end

    def supersede_invocation!(invocation, result)
      invocation.reload
      return invocation unless invocation.status_started?

      invocation.update!(
        status: :superseded,
        returned_model: result.returned_model,
        provider_request_id: result.provider_request_id,
        sanitized_request: result.sanitized_request,
        sanitized_response: result.sanitized_response,
        input_tokens: result.input_tokens,
        cached_input_tokens: result.cached_input_tokens,
        output_tokens: result.output_tokens,
        total_tokens: result.total_tokens,
        latency_ms: result.latency_ms,
        provider_metadata: result.provider_metadata,
        failure_category: "claim_lost",
        failure_message: "The provider response arrived after claim ownership changed.",
        finished_at: Time.current
      )
    end

    def finish_failed_invocation!(invocation, error, status: :failed)
      invocation.reload
      return invocation unless invocation.status_started?

      request_snapshot = error.sanitized_request.presence ||
        invocation.sanitized_request
      invocation.update!(
        status:,
        returned_model: error.returned_model,
        provider_request_id: error.provider_request_id,
        sanitized_request: request_snapshot,
        sanitized_response: error.sanitized_response,
        response_status: error.response_status,
        failure_category: error.category,
        failure_class: error.class.name,
        failure_message: error.message,
        retry_after_seconds: error.retry_after_seconds,
        possible_duplicate_cost: error.possible_duplicate_cost,
        provider_metadata: error.provider_metadata,
        finished_at: Time.current
      )
    end

    def current_claim?(interpretation, claim)
      interpretation.status_running? &&
        interpretation.claim_generation == claim.generation &&
        ActiveSupport::SecurityUtils.secure_compare(
          interpretation.claim_token.to_s,
          claim.token
        )
    end

    def bound_configuration_current?(interpretation)
      account = Account.find(interpretation.account_id)
      return false unless account.conversation_ai_mode_shadow?

      selected = account.conversation_ai_provider.presence ||
        ENV["CONVERSATION_AI_PROVIDER"].to_s.strip.presence
      selected == interpretation.provider &&
        ConversationAi::Configuration.for_provider(selected).available?
    end

    def cancel!(interpretation, reason)
      interpretation.update!(
        status: :canceled,
        scheduling_status: :canceled,
        scheduling_token: nil,
        scheduling_claimed_at: nil,
        claim_token: nil,
        claimed_at: nil,
        failure_category: "canceled",
        failure_reason: reason,
        canceled_at: Time.current
      )
    end

    def stale_source?(interpretation, work_unit)
      scope = interpretation.account.conversation_messages
        .where(id: work_unit.message_ids)
      source_time = interpretation.source_message.occurred_at
      scope.where(
        "COALESCE(received_at, sent_at, created_at) > ?",
        source_time
      ).exists?
    end

    def retry_delay(attempt, retry_after)
      return retry_after.seconds if retry_after

      [ attempt**2 * 30, 30.minutes.to_i ].min.seconds
    end

    def provider_client(interpretation)
      return client if client

      configuration = ConversationAi::Configuration.for_provider(
        interpretation.provider
      )
      configuration.validate!
      provider_adapter(interpretation).new(
        api_key: configuration.api_key,
        model: interpretation.requested_model
      )
    end

    def provider_adapter(interpretation)
      ConversationAi::ProviderRegistry.fetch(interpretation.provider)
    end

    def semantic_request_snapshot(interpretation)
      ConversationAi::AuditSnapshot.bounded(
        "system_instructions" =>
          ConversationAi::Prompts::ClassifierV1::SYSTEM_INSTRUCTIONS,
        "untrusted_context" => interpretation.context_snapshot,
        "json_schema" => ConversationAi::OutputSchema.schema,
        "maximum_output_tokens" => 2_500,
        "prompt_version" => interpretation.semantic_prompt_version,
        "schema_version" => interpretation.result_schema_version
      )
    end
end

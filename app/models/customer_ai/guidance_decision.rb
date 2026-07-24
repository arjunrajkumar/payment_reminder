class CustomerAi::GuidanceDecision
  class Conflict < StandardError; end

  class << self
    def approve!(
      signal:,
      actor_user:,
      token:,
      idempotency_key:,
      structured_guidance:,
      summary:,
      note: nil
    )
      new(
        signal:,
        actor_user:,
        token:,
        idempotency_key:,
        structured_guidance:,
        summary:,
        note:
      ).approve!
    end

    def reject!(signal:, actor_user:, token:, idempotency_key:, note:)
      new(
        signal:,
        actor_user:,
        token:,
        idempotency_key:,
        note:
      ).reject!
    end
  end

  def initialize(**attributes)
    attributes.each { |key, value| instance_variable_set("@#{key}", value) }
  end

  def approve!
    verify!
    signal.customer.with_lock do
      locked_signal = signal.account.customer_ai_signals.lock.find(signal.id)
      if locked_signal.status_approved?
        existing = locked_signal.guidance_revisions.find_by(
          idempotency_key:
        )
        return existing if existing && approval_replay_matches?(
          locked_signal,
          existing
        )

        raise Conflict, "That signal decision was already recorded differently."
      end
      raise Conflict, "This signal has already been decided." unless
        locked_signal.status_proposed?

      profile = signal.customer.customer_ai_profile ||
        CustomerAiProfile.create!(
          account: signal.account,
          customer: signal.customer
        )
      profile.with_lock do
        previous = profile.active_guidance_revision
        revision = profile.guidance_revisions.create!(
          account: signal.account,
          revision_number: profile.guidance_revisions.maximum(:revision_number).to_i + 1,
          status: :active,
          source_signal: locked_signal,
          author_kind: :user,
          author_user: actor_user,
          author_snapshot: ConversationAi::ActorSnapshot.for(actor_user),
          summary: summary.to_s.strip,
          structured_guidance: normalized_guidance,
          evidence_snapshot: locked_signal.evidence,
          idempotency_key:,
          activated_at: Time.current
        )
        if previous
          CustomerAiGuidanceRevision.where(id: previous.id).update_all(
            status: CustomerAiGuidanceRevision.statuses.fetch(:superseded),
            superseded_at: Time.current,
            updated_at: Time.current
          )
        end
        profile.update!(active_guidance_revision: revision)
        locked_signal.update!(
          status: :approved,
          decided_by_user: actor_user,
          decider_snapshot: ConversationAi::ActorSnapshot.for(actor_user),
          decided_at: Time.current,
          decision_note: note.to_s.strip.presence,
          decision_idempotency_key: idempotency_key
        )
        record_events!(locked_signal, revision)
        revision
      end
    end
  end

  def reject!
    verify!
    signal.with_lock do
      if signal.status_rejected?
        return signal if rejection_replay_matches?

        raise Conflict, "That signal decision was already recorded differently."
      end
      raise Conflict, "This signal has already been decided." unless signal.status_proposed?

      signal.update!(
        status: :rejected,
        decided_by_user: actor_user,
        decider_snapshot: ConversationAi::ActorSnapshot.for(actor_user),
        decided_at: Time.current,
        decision_note: normalized_rejection_note,
        decision_idempotency_key: idempotency_key
      )
      ConversationEvent.record_ai_once!(
        interpretation: signal.conversation_interpretation,
        role: "signal-rejected:#{signal.id}",
        kind: :customer_ai_signal_rejected,
        actor_kind: :user,
        actor_user:,
        metadata: { "customer_ai_signal_id" => signal.id }
      )
      signal
    end
  end

  private
    attr_reader :signal,
      :actor_user,
      :token,
      :idempotency_key,
      :structured_guidance,
      :summary,
      :note

    def verify!
      raise ActiveRecord::RecordNotFound unless signal.account_id == actor_user.account_id
      if signal.status_proposed? ||
          signal.decision_idempotency_key != idempotency_key.to_s.strip
        CustomerAi::GuidanceSnapshot.verify!(
          token:,
          signal:,
          idempotency_key:
        )
      else
        CustomerAi::GuidanceSnapshot.verify_replay!(
          token:,
          signal:,
          idempotency_key:
        )
      end
    end

    def normalized_guidance
      CustomerAi::GuidanceAttributes.normalize(structured_guidance)
    end

    def rejection_replay_matches?
      signal.decision_idempotency_key == idempotency_key.to_s.strip &&
        signal.decision_note == normalized_rejection_note &&
        signal.decider_snapshot == ConversationAi::ActorSnapshot.for(actor_user)
    end

    def approval_replay_matches?(locked_signal, revision)
      locked_signal.decision_idempotency_key == idempotency_key.to_s.strip &&
        locked_signal.decision_note == note.to_s.strip.presence &&
        locked_signal.decider_snapshot ==
          ConversationAi::ActorSnapshot.for(actor_user) &&
        revision.summary == summary.to_s.strip &&
        revision.structured_guidance == normalized_guidance &&
        revision.author_snapshot == ConversationAi::ActorSnapshot.for(actor_user)
    end

    def normalized_rejection_note
      note.to_s.strip.presence || "Rejected"
    end

    def record_events!(locked_signal, revision)
      interpretation = locked_signal.conversation_interpretation
      ConversationEvent.record_ai_once!(
        interpretation:,
        role: "signal-approved:#{locked_signal.id}",
        kind: :customer_ai_signal_approved,
        actor_kind: :user,
        actor_user:,
        metadata: {
          "customer_ai_signal_id" => locked_signal.id,
          "customer_ai_guidance_revision_id" => revision.id
        }
      )
      ConversationEvent.record_ai_once!(
        interpretation:,
        role: "guidance-activated:#{revision.id}",
        kind: :customer_ai_guidance_activated,
        actor_kind: :user,
        actor_user:,
        metadata: {
          "customer_ai_guidance_revision_id" => revision.id
        }
      )
    end
end

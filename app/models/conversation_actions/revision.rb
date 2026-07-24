class ConversationActions::Revision
  def self.record!(**attributes)
    new(**attributes).record!
  end

  def initialize(
    action:,
    author_kind:,
    author_user:,
    user_facing_summary:,
    rationale:,
    proposed_reply: nil,
    base_revision_id: nil,
    proposed_reply_subject: nil,
    proposed_reply_body: nil,
    idempotency_key:,
    snapshot_token:,
    at: Time.current
  )
    @action = action
    @author_kind = author_kind.to_s
    @author_user = author_user
    @user_facing_summary = user_facing_summary
    @rationale = rationale
    @proposed_reply = proposed_reply
    @base_revision_id = base_revision_id&.to_i
    @proposed_reply_subject = proposed_reply_subject
    @proposed_reply_body = proposed_reply_body
    @idempotency_key = idempotency_key.to_s.strip
    @snapshot_token = snapshot_token
    @at = at
  end

  def record!
    validate_actor!
    owner = Conversations::ReviewWorkUnit.reconcile_workflow_owner!(
      conversation: action.conversation
    )
    action.reload
    existing = action.revisions.find_by(idempotency_key:)
    return repair_attention(validate_existing!(existing)) if existing

    payload = ConversationActions::ActionSnapshot.verify!(
      token: snapshot_token,
      action:,
      idempotency_key:
    )

    revision = nil
    action.with_lock do
      action.reload
      if existing = action.revisions.find_by(idempotency_key:)
        revision = validate_existing!(existing)
        next
      end
      ConversationActions::ActionSnapshot.ensure_current!(payload:, action:)
      unless action.status_pending_approval?
        raise ConversationActions::InvalidTransition,
          "Only pending actions can be revised."
      end

      previous = action.current_revision
      if editable_reply? && previous.id != base_revision_id
        raise ConversationActions::StaleControl,
          ConversationActions::ActionSnapshot::ERROR_MESSAGE
      end
      revision = action.revisions.create!(
        revision_number: previous.revision_number + 1,
        invoice: owner.invoice,
        customer: owner.customer,
        author_kind:,
        author_user:,
        user_facing_summary:,
        rationale:,
        arguments: previous.arguments.deep_dup,
        proposed_reply: proposed_reply_for(previous),
        idempotency_key:,
        created_at: at,
        updated_at: at
      )
      ConversationEvent.record!(
        conversation: owner,
        kind: :conversation_action_revised,
        actor_kind: author_kind,
        actor_user: author_user,
        metadata: {
          "conversation_action_id" => action.id,
          "conversation_action_revision_id" => revision.id,
          "revision_number" => revision.revision_number,
          "previous_revision_number" => previous.revision_number,
          "action_type" => action.action_type,
          "status" => action.status
        },
        created_at: at
      )
    end
    repair_attention(revision)
    revision
  rescue ActiveRecord::RecordNotUnique
    repair_attention(
      validate_existing!(action.revisions.find_by!(idempotency_key:))
    )
  end

  private
    attr_reader :action,
      :author_kind,
      :author_user,
      :user_facing_summary,
      :rationale,
      :proposed_reply,
      :base_revision_id,
      :proposed_reply_subject,
      :proposed_reply_body,
      :idempotency_key,
      :snapshot_token,
      :at

    def validate_actor!
      valid = if author_kind == "user"
        author_user&.account_id == action.account_id
      else
        author_user.nil?
      end
      raise ActiveRecord::RecordNotFound unless valid
      raise ArgumentError, "Idempotency key is required." if idempotency_key.blank?
    end

    def validate_existing!(revision)
      expected = {
        author_kind:,
        author_user_id: author_user&.id,
        user_facing_summary:,
        rationale:
      }
      if editable_reply?
        base = action.revisions.find_by(
          revision_number: revision.revision_number - 1
        )
        expected[:base_revision_id] = base_revision_id
        actual = expected.transform_keys do |name|
          name == :base_revision_id ? :id : name
        end
        exact = base.present? &&
          actual.all? do |name, value|
            record = name == :id ? base : revision
            record.public_send(name) == value
          end &&
          revision.proposed_reply["subject"].to_s == proposed_reply_subject.to_s &&
          revision.proposed_reply["body"].to_s == proposed_reply_body.to_s
        return revision if exact
      else
        expected[:proposed_reply] = proposed_reply
        return revision if expected.all? do |name, value|
          revision.public_send(name) == value
        end
      end

      raise ConversationActions::IdempotencyConflict,
        "That revision idempotency key was already used."
    end

    def editable_reply?
      base_revision_id.present?
    end

    def proposed_reply_for(previous)
      return proposed_reply unless editable_reply?

      previous.proposed_reply.deep_dup.merge(
        "subject" => proposed_reply_subject.to_s,
        "body" => proposed_reply_body.to_s
      )
    end

    def repair_attention(result)
      Conversations::Attention.recompute!(
        conversation: Conversations::ReviewWorkUnit.workflow_owner_for(
          conversation: action.conversation
        ),
        at:
      )
      result
    end
end

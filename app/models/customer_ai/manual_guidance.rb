class CustomerAi::ManualGuidance
  class << self
    def create!(customer:, actor_user:, idempotency_key:, summary:, structured_guidance:)
      raise ActiveRecord::RecordNotFound unless customer.account_id == actor_user.account_id

      customer.with_lock do
        profile = customer.customer_ai_profile ||
          CustomerAiProfile.create!(
            account: customer.account,
            customer:
          )
        profile.with_lock do
          if existing = profile.guidance_revisions.find_by(idempotency_key:)
            return existing
          end
          attributes = CustomerAi::GuidanceAttributes.normalize(
            structured_guidance
          )
          previous = profile.active_guidance_revision
          revision = profile.guidance_revisions.create!(
            account: customer.account,
            revision_number: profile.guidance_revisions.maximum(:revision_number).to_i + 1,
            status: :active,
            author_kind: :user,
            author_user: actor_user,
            author_snapshot: ConversationAi::ActorSnapshot.for(actor_user),
            summary: summary,
            structured_guidance: attributes,
            evidence_snapshot: { "source" => "manual" },
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
          revision
        end
      end
    end
  end
end

class Customers::AiGuidanceRevisionsController < ApplicationController
  def create
    customer = Current.account.customers.find(params[:customer_id])
    attributes = guidance_params
    CustomerAi::ManualGuidance.create!(
      customer:,
      actor_user: Current.user,
      idempotency_key: attributes.fetch(:idempotency_key),
      summary: attributes.fetch(:summary),
      structured_guidance: attributes.fetch(:structured_guidance, {})
    )
    redirect_back fallback_location: conversations_path,
      notice: "Customer guidance activated."
  rescue ActiveRecord::RecordInvalid => error
    redirect_back fallback_location: conversations_path, alert: error.message
  end

  private
    def guidance_params
      params.expect(ai_guidance_revision: [
        :idempotency_key,
        :summary,
        structured_guidance: CustomerAiGuidanceRevision::ALLOWED_GUIDANCE_KEYS
      ])
    end
end

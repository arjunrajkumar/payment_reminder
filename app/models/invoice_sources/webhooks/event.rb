class InvoiceSources::Webhooks::Event < ApplicationRecord
  self.table_name = "invoice_source_webhook_events"

  belongs_to :invoice_source

  attribute :payload, default: -> { {} }

  enum :status, {
    pending: "pending",
    processing: "processing",
    processed: "processed",
    ignored: "ignored",
    failed: "failed"
  }

  validates :provider, :provider_event_id, :event_type, :payload, presence: true
  validates :provider_event_id, uniqueness: { scope: :invoice_source_id }

  scope :ordered, -> { order(occurred_at: :desc, created_at: :desc) }

  def self.record(attributes)
    event = find_or_initialize_by(
      invoice_source: attributes.fetch(:invoice_source),
      provider_event_id: attributes.fetch(:provider_event_id)
    )

    return [ event, false ] if event.persisted?

    event.assign_attributes(attributes)
    event.save!
    [ event, true ]
  rescue ActiveRecord::RecordNotUnique
    [
      find_by!(
        invoice_source: attributes.fetch(:invoice_source),
        provider_event_id: attributes.fetch(:provider_event_id)
      ),
      false
    ]
  end

  def process!
    return if processed? || ignored?

    with_lock do
      return if processed? || ignored?

      processing!
      if process_invoice_event!
        update!(status: :processed, processed_at: Time.current, last_error: nil)
      else
        update!(status: :ignored, processed_at: Time.current, last_error: nil)
      end
    end
  rescue => error
    update!(status: :failed, last_error: error.message)
    raise
  end

  private
    def process_invoice_event!
      if resource_type.to_s.casecmp?("invoice") && resource_id.present?
        invoice_source.sync_invoice!(external_id: resource_id)
        true
      else
        false
      end
    end
end

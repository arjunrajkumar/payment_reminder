class InvoiceReminders::StageDecision
  SUPPRESSION_REASONS = %w[
    active_collection_hold
    active_payment_promise
    recent_outbound_message
  ].freeze

  Result = Data.define(:stage, :connection, :reminder, :reason, :context) do
    def deliverable?
      reason.nil?
    end

    def suppression?
      reason.in?(SUPPRESSION_REASONS)
    end
  end

  def self.call(
    invoice:,
    category:,
    day_offset:,
    delivery_job_id: nil,
    delivery_availability: nil,
    on: Date.current
  )
    new(
      invoice:,
      category:,
      day_offset:,
      delivery_job_id:,
      delivery_availability:,
      on:
    ).call
  end

  def initialize(
    invoice:,
    category:,
    day_offset:,
    delivery_job_id:,
    delivery_availability:,
    on:
  )
    @invoice = invoice
    @category = category
    @day_offset = day_offset
    @delivery_job_id = delivery_job_id
    @delivery_availability = delivery_availability
    @on = on
  end

  def call
    connection_result = delivery_availability ||
      EmailConnection::DeliveryAvailability.call(account: invoice.account)
    return skipped(connection_result.reason) unless connection_result.ready?
    return skipped(:disabled_account) unless invoice.account.automatic_invoice_reminders_enabled?
    return skipped(:not_outstanding) unless invoice.outstanding?

    stage = current_stage
    return skipped(:stage_not_in_current_schedule, payer_segment: payer_segment) unless stage
    return skipped(:suppressed_stage, stage:) if stage_suppressed?(stage)

    reminder = reminder_for(stage)
    unless reminder.nil? || reminder.conversation_message.delivery_owned_by?(delivery_job_id)
      return skipped(:duplicate_stage, stage:)
    end

    unless stage_due?(stage, reminder:)
      return skipped(:stage_not_due, stage:, due_on: invoice.due_on || "none")
    end
    hold_suppression = active_hold_suppression_for(invoice)
    if hold_suppression
      return skipped(
        hold_suppression.fetch(:reason),
        stage:,
        **hold_suppression.fetch(:context)
      )
    end
    unless invoice.customer.reminder_email_addresses.any?
      return skipped(:missing_email, stage:, customer_id: invoice.customer_id)
    end

    suppression = suppression_for(invoice)
    return skipped(suppression.fetch(:reason), stage:, **suppression.fetch(:context)) if suppression

    Result.new(
      stage:,
      connection: connection_result.connection,
      reminder:,
      reason: nil,
      context: {}
    )
  end

  private
    attr_reader :invoice,
      :category,
      :day_offset,
      :delivery_job_id,
      :delivery_availability,
      :on

    def current_stage
      invoice.account.invoice_schedules.find_by(
        kind: payer_segment,
        category:,
        day_offset:
      )
    end

    def payer_segment
      invoice.customer.payer_segment
    end

    def stage_suppressed?(stage)
      invoice.invoice_reminder_suppressions.for_stage(stage).exists?
    end

    def reminder_for(stage)
      invoice.invoice_reminders.includes(:conversation_message).for_stage(stage).first
    end

    def stage_due?(stage, reminder:)
      return true if stage.due_for?(invoice, on:)
      return false unless reminder&.conversation_message&.delivery_owned_by?(delivery_job_id)

      stage.due_for?(invoice, on: reminder.created_at.in_time_zone.to_date)
    end

    def suppression_for(invoice)
      if invoice.payment_promises.status_active.exists?
        return { reason: :active_payment_promise, context: {} }
      end

      recently_contacted = invoice.conversation_messages
        .successful_outbound
        .sent_after(ConversationMessage::OUTBOUND_CONTACT_COOLDOWN.ago)
        .exists?
      { reason: :recent_outbound_message, context: {} } if recently_contacted
    end

    def active_hold_suppression_for(invoice)
      holds = invoice.active_collection_holds.reorder(:id).to_a
      return if holds.empty?

      {
        reason: :active_collection_hold,
        context: {
          collection_hold_ids: holds.map(&:id),
          collection_hold_reasons: holds.map(&:reason).uniq
        }
      }
    end

    def skipped(reason, stage: nil, **context)
      Result.new(stage:, connection: nil, reminder: nil, reason: reason.to_s, context:)
    end
end

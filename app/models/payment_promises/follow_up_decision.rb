class PaymentPromises::FollowUpDecision
  Result = Data.define(
    :payment_promise,
    :invoice,
    :message,
    :connection,
    :resolution,
    :reason,
    :context
  ) do
    def ready?
      resolution.nil? && reason.nil?
    end

    def resolvable?
      resolution.present?
    end
  end

  class << self
    def before_refresh(payment_promise:, on: Date.current)
      new(
        payment_promise:,
        delivery_job_id: nil,
        delivery_availability: nil,
        check_delivery: false,
        on:
      ).call
    end

    def for_delivery(
      payment_promise:,
      delivery_job_id:,
      delivery_availability: nil,
      on: Date.current
    )
      new(
        payment_promise:,
        delivery_job_id:,
        delivery_availability:,
        check_delivery: true,
        on:
      ).call
    end
  end

  def initialize(
    payment_promise:,
    delivery_job_id:,
    delivery_availability:,
    check_delivery:,
    on:
  )
    @payment_promise = payment_promise
    @delivery_job_id = delivery_job_id
    @delivery_availability = delivery_availability
    @check_delivery = check_delivery
    @on = on
  end

  def call
    return skipped(:not_due) unless follow_up_due?

    invoice = payment_promise.invoice.reload
    message = payment_promise.follow_up_message
    return resolved(:followed_up, invoice:, message:) if message&.status_sent?
    return resolved(:follow_up_failed, invoice:, message:) if message&.status_failed?

    invoice_resolution = resolution_for(invoice)
    return resolved(invoice_resolution, invoice:, message:) if invoice_resolution
    holds = invoice.active_collection_holds.reorder(:id).to_a
    if holds.any?
      return skipped(
        :active_collection_hold,
        invoice:,
        message:,
        collection_hold_ids: holds.map(&:id),
        collection_hold_reasons: holds.map(&:reason).uniq
      )
    end
    return ready(invoice:, message:) unless check_delivery?

    if message && !message.delivery_owned_by?(delivery_job_id)
      return skipped(:outbound_delivery_in_progress, invoice:, message:)
    end
    if recently_contacted?(invoice, excluding: message)
      return skipped(:recent_outbound_message, invoice:, message:)
    end

    account = payment_promise.account.reload
    return skipped(:disabled_account, invoice:, message:) unless account.automatic_invoice_reminders_enabled?

    availability = delivery_availability ||
      EmailConnection::DeliveryAvailability.call(account:)
    return skipped(availability.reason, invoice:, message:) unless availability.ready?

    if invoice.customer.reminder_email_addresses.empty?
      return skipped(:missing_email, invoice:, message:, customer_id: invoice.customer_id)
    end

    unless message
      if invoice.conversation_messages.direction_outbound.status_pending.lock.exists?
        return skipped(:outbound_delivery_in_progress, invoice:)
      end
    end

    ready(invoice:, message:, connection: availability.connection)
  end

  private
    attr_reader :payment_promise,
      :delivery_job_id,
      :delivery_availability,
      :on

    def check_delivery?
      @check_delivery
    end

    def follow_up_due?
      payment_promise&.status_active? && payment_promise.follow_up_on <= on
    end

    def resolution_for(invoice)
      return if invoice.outstanding?
      return :fulfilled if invoice.paid? || zero_balance_open_invoice?(invoice)

      :cancelled
    end

    def zero_balance_open_invoice?(invoice)
      invoice.status_open? && invoice.amount_due.present? && !invoice.amount_due.to_d.positive?
    end

    def recently_contacted?(invoice, excluding:)
      scope = invoice.conversation_messages
        .successful_outbound
        .sent_after(ConversationMessage::OUTBOUND_CONTACT_COOLDOWN.ago)
      scope = scope.where.not(id: excluding.id) if excluding
      scope.exists?
    end

    def ready(invoice:, message:, connection: nil)
      Result.new(
        payment_promise:,
        invoice:,
        message:,
        connection:,
        resolution: nil,
        reason: nil,
        context: {}
      )
    end

    def resolved(resolution, invoice:, message:)
      Result.new(
        payment_promise:,
        invoice:,
        message:,
        connection: nil,
        resolution:,
        reason: nil,
        context: {}
      )
    end

    def skipped(reason, invoice: nil, message: nil, **context)
      Result.new(
        payment_promise:,
        invoice:,
        message:,
        connection: nil,
        resolution: nil,
        reason: reason.to_s,
        context:
      )
    end
end

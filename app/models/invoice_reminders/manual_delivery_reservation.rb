class InvoiceReminders::ManualDeliveryReservation
  Result = Data.define(:message, :connection, :mail_message, :reason, :context) do
    def reserved?
      message.present? && connection.present? && mail_message.present?
    end
  end

  def self.call(invoice:, delivery_job_id:)
    new(invoice:, delivery_job_id:).call
  end

  def initialize(invoice:, delivery_job_id:)
    @invoice = invoice
    @delivery_job_id = delivery_job_id
  end

  def call
    reservation = nil

    Receivables::AccountLock.synchronize(account: invoice.account) do
      invoice.with_lock do
        invoice.reload
        if owned_message && !owned_message.status_pending?
          reservation = skipped(completed_delivery_reason)
          next
        end
        reservation = eligibility_failure
        next if reservation

        mail_message = ManualInvoiceReminderMailer.reminder(invoice).message
        connection = delivery_availability.connection
        message = owned_pending_message || reserve_new_message(mail_message:, connection:)

        unless message
          reservation = skipped(:outbound_delivery_in_progress)
          next
        end

        unless message.bind_delivery_mailbox!(connection:, job_id: delivery_job_id)
          reservation = skipped(:email_connection_replaced)
          next
        end

        message.apply_internet_message_id!(mail_message)

        if owned_pending_message && !message.refresh_delivery_attempt!(
          job_id: delivery_job_id,
          mail_message:
        )
          reservation = skipped(:delivery_reservation_conflict)
          next
        end

        reservation = Result.new(
          message:,
          connection:,
          mail_message:,
          reason: nil,
          context: {}
        )
      end
    end

    reservation
  rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique
    skipped(:delivery_reservation_conflict)
  end

  private
    attr_reader :invoice, :delivery_job_id

    def eligibility_failure
      return skipped(:not_outstanding) unless invoice.outstanding?
      return skipped(delivery_availability.reason) unless delivery_availability.ready?
      return skipped(:missing_email, customer_id: invoice.customer_id) if
        invoice.customer.reminder_email_addresses.empty?

      return if owned_pending_message
      skipped(:outbound_delivery_in_progress) if
        invoice.conversation_messages.direction_outbound.status_pending.exists?
    end

    def delivery_availability
      @delivery_availability ||= EmailConnection::DeliveryAvailability.call(
        account: invoice.account
      )
    end

    def owned_pending_message
      owned_message if owned_message&.status_pending?
    end

    def owned_message
      @owned_message ||= invoice.conversation_messages
        .direction_outbound
        .kind_manual_reminder
        .find_by(delivery_job_id:)
    end

    def completed_delivery_reason
      return :already_sent if owned_message.status_sent?
      return :delivery_unconfirmed if owned_message.delivery_uncertain?

      :delivery_failed
    end

    def reserve_new_message(mail_message:, connection:)
      return if invoice.conversation_messages.direction_outbound.status_pending.exists?

      invoice.conversation_messages.create!(
        {
          account: invoice.account,
          conversation: Conversation.for_invoice!(invoice:),
          email_connection: connection,
          email_connection_generation: connection.credential_generation,
          provider_account_id: connection.provider_account_id,
          direction: :outbound,
          kind: :manual_reminder,
          status: :pending,
          delivery_job_id:,
          delivery_attempted_at: Time.current
        }.merge(ConversationMessages::Content.from_mail(mail_message).attributes)
      )
    end

    def skipped(reason, **context)
      Result.new(
        message: nil,
        connection: nil,
        mail_message: nil,
        reason: reason.to_s,
        context:
      )
    end
end

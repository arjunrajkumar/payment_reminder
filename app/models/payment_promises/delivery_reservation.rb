class PaymentPromises::DeliveryReservation
  Result = Data.define(
    :payment_promise,
    :message,
    :connection,
    :mail_message,
    :resolution,
    :reason,
    :context
  ) do
    def reserved?
      message.present? && mail_message.present?
    end

    def resolved?
      resolution.present?
    end
  end

  def self.call(payment_promise:, delivery_job_id:, on: Date.current)
    new(payment_promise:, delivery_job_id:, on:).call
  end

  def initialize(payment_promise:, delivery_job_id:, on:)
    @payment_promise = payment_promise
    @delivery_job_id = delivery_job_id
    @on = on
  end

  def call
    reservation = nil

    Receivables::AccountLock.synchronize(account: payment_promise.account) do
      payment_promise.invoice.with_lock do
        payment_promise.reload
        decision = PaymentPromises::FollowUpDecision.for_delivery(
          payment_promise:,
          delivery_job_id:,
          on:
        )

        if decision.resolvable?
          payment_promise.resolve_follow_up!(as: decision.resolution)
          reservation = resolved(decision)
          next
        end

        unless decision.ready?
          cancel_owned_retry_after_recent_contact(decision) if
            decision.reason == "recent_outbound_message"
          reservation = skipped(decision)
          next
        end

        mail_message = PaymentPromiseMailer.follow_up(payment_promise).message
        message = decision.message || reserve_new_message(
          mail_message:,
          connection: decision.connection
        )
        unless message.bind_delivery_mailbox!(
          connection: decision.connection,
          job_id: delivery_job_id
        )
          reservation = skipped_reason(:email_connection_replaced)
          next
        end

        message.apply_internet_message_id!(mail_message)

        if decision.message && !message.refresh_delivery_attempt!(
          job_id: delivery_job_id,
          mail_message:
        )
          reservation = skipped_reason(:delivery_reservation_conflict)
          next
        end

        reservation = Result.new(
          payment_promise:,
          message:,
          connection: decision.connection,
          mail_message:,
          resolution: nil,
          reason: nil,
          context: {}
        )
      end
    end

    reservation
  rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique
    skipped_reason(:delivery_reservation_conflict)
  end

  private
    attr_reader :payment_promise, :delivery_job_id, :on

    def reserve_new_message(mail_message:, connection:)
      message = payment_promise.invoice.conversation_messages.create!(
        {
          account: payment_promise.account,
          conversation: Conversation.for_invoice!(invoice: payment_promise.invoice),
          email_connection: connection,
          email_connection_generation: connection.credential_generation,
          provider_account_id: connection.provider_account_id,
          direction: :outbound,
          kind: :promise_follow_up,
          status: :pending,
          delivery_job_id:,
          delivery_attempted_at: Time.current
        }.merge(ConversationMessages::Content.from_mail(mail_message).attributes)
      )
      payment_promise.update!(follow_up_message: message)
      message
    end

    def cancel_owned_retry_after_recent_contact(decision)
      return unless decision.message

      PaymentPromises::PendingDeliveryCancellation.call(
        payment_promise:,
        message: decision.message,
        delivery_job_id:,
        failure_reason: "Promise follow-up was not sent because a newer outbound contact exists."
      )
    end

    def resolved(decision)
      Result.new(
        payment_promise:,
        message: decision.message,
        connection: nil,
        mail_message: nil,
        resolution: decision.resolution,
        reason: nil,
        context: decision.context
      )
    end

    def skipped(decision)
      Result.new(
        payment_promise:,
        message: decision.message,
        connection: nil,
        mail_message: nil,
        resolution: nil,
        reason: decision.reason,
        context: decision.context
      )
    end

    def skipped_reason(reason)
      Result.new(
        payment_promise:,
        message: nil,
        connection: nil,
        mail_message: nil,
        resolution: nil,
        reason: reason.to_s,
        context: {}
      )
    end
end

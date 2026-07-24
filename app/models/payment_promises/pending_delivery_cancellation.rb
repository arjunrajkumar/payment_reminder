class PaymentPromises::PendingDeliveryCancellation
  def self.call(payment_promise:, message:, delivery_job_id:, failure_reason:)
    cancelled = false
    payment_promise.invoice.with_lock do
      payment_promise.reload
      message.reload
      message.with_lock do
        next unless payment_promise.status_active?
        next unless payment_promise.follow_up_message_id == message.id
        next unless message.delivery_owned_by?(delivery_job_id)
        next if message.provider_delivery_claimed?

        message.update!(
          status: :failed,
          sent_at: nil,
          provider_message_id: nil,
          provider_thread_id: nil,
          failure_reason:,
          delivery_uncertain: false
        )
        payment_promise.update!(follow_up_message: nil)
        cancelled = true
      end
    end
    cancelled
  end
end

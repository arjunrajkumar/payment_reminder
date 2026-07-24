class PaymentPromises::HoldPause
  def self.call(payment_promise:, delivery_job_id:)
    message = payment_promise.reload.follow_up_message
    return unless message&.delivery_owned_by?(delivery_job_id)

    PaymentPromises::FinalDeliveryClaim.call(
      payment_promise:,
      message:,
      delivery_job_id:,
      cancel_if_hold_released: true
    )
  end
end

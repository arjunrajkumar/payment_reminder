class InvoiceSources::Webhooks::ProcessJob < ApplicationJob
  queue_as :webhooks

  retry_on InvoiceSources::Stripe::OauthClient::Error,
    InvoiceSources::Xero::OauthClient::Error,
    wait: :polynomially_longer,
    attempts: 5

  discard_on ActiveJob::DeserializationError

  def perform(webhook_event)
    webhook_event.process!
  end
end

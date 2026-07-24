class ConversationActions::Commands::RecordPaymentPromise <
    ConversationActions::Commands::Base
  def call
    unless invoice.outstanding?
      raise ConversationActions::Commands::Unsafe,
        "A payment promise cannot be recorded because the invoice is not outstanding."
    end
    promised_on = definition.arguments.fetch("promised_on")
    if promised_on < at.in_time_zone(
      execution.account.try(:timezone).presence || Time.zone.name
    ).to_date
      raise ConversationActions::Commands::Unsafe,
        "A payment promise cannot be recorded for a past date."
    end
    existing = invoice.payment_promises.find_by(source_message:)
    if existing && existing.promised_on != promised_on
      raise ConversationActions::Commands::Stale,
        "This customer email is already linked to a different payment date."
    end
    reject_older_source!

    payment_promise = existing || PaymentPromise.record!(
      invoice:,
      source_message:,
      promised_on:
    )
    outcome = existing ? "already_recorded" : "recorded"
    result(
      result_code: existing ?
        "payment_promise_already_recorded" :
        "payment_promise_recorded",
      result_metadata: {
        "promised_on" => payment_promise.promised_on.iso8601,
        "outcome" => outcome
      },
      payment_promise:,
      effect_mutated: existing.nil?,
      rendered_reply: render_reply(
        outcome: {
          "promised_on" => payment_promise.promised_on,
          "outcome" => outcome
        }
      )
    )
  end

  private
    def reject_older_source!
      latest = invoice.payment_promises.includes(:source_message).max_by do |promise|
        source_order(promise.source_message)
      end
      newer = latest &&
        (source_order(latest.source_message) <=> source_order(source_message)) == 1
      return unless newer

      raise ConversationActions::Commands::Stale,
        "A newer payment promise has already been recorded."
    end

    def source_order(message)
      [ message.received_at || message.created_at, message.id ]
    end
end

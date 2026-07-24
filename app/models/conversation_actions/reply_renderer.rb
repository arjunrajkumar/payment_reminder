require "ipaddr"

class ConversationActions::ReplyRenderer
  class Unanswerable < ConversationActions::Error; end

  Rendered = Data.define(:subject, :body)

  TRUSTED_INVOICE_HOSTS = {
    "stripe" => %w[invoice.stripe.com pay.stripe.com],
    "xero" => %w[in.xero.com]
  }.freeze

  class << self
    def render!(
      definition:,
      invoice:,
      account:,
      at: Time.current,
      outcome: {}
    )
      new(
        definition:,
        invoice:,
        account:,
        at:,
        outcome:
      ).render!
    end
  end

  def initialize(definition:, invoice:, account:, at:, outcome:)
    @definition = definition
    @invoice = invoice
    @account = account
    @at = at
    @outcome = outcome.to_h.stringify_keys
  end

  def render!
    case definition.action_type
    when "record_payment_promise"
      promised_on = outcome["promised_on"] ||
        definition.arguments.fetch("promised_on")
      rendered(
        "Payment date noted",
        "Thank you. We recorded your payment date as #{date(promised_on)}."
      )
    when "answer_due_date"
      value = invoice.due_on ||
        raise(Unanswerable, "The invoice due date is unavailable.")
      rendered(
        "Invoice due date",
        "Invoice #{invoice_reference} is due on #{date(value)}."
      )
    when "answer_payment_status"
      render_payment_status
    when "answer_outstanding_amount"
      render_outstanding_amount
    when "resend_invoice"
      rendered(
        "Invoice copy",
        "You can view invoice #{invoice_reference} at #{safe_invoice_url!}."
      )
    when "add_recipient"
      rendered("Recipient update", recipient_update_body)
    when "open_dispute"
      rendered(
        "Invoice query received",
        outcome["outcome"] == "dispute_already_open" ?
          "Automated reminders are already paused while a person reviews your query." :
          "We have paused automated reminders for this invoice while a person reviews your query."
      )
    else
      raise Unanswerable, "This action does not produce a reply."
    end
  end

  private
    attr_reader :definition, :invoice, :account, :at, :outcome

    def render_payment_status
      body = case invoice.status
      when "paid"
        suffix = invoice.paid_on ? " on #{date(invoice.paid_on)}" : ""
        "Invoice #{invoice_reference} is recorded as paid#{suffix}."
      when "void"
        "Invoice #{invoice_reference} is void."
      when "uncollectible"
        "Invoice #{invoice_reference} is no longer being collected."
      when "open"
        amount = normalized_amount
        if amount.nil?
          raise Unanswerable, "The invoice balance is unavailable."
        elsif amount <= 0
          "Invoice #{invoice_reference} has no outstanding balance."
        elsif invoice.due_on.present? && invoice.due_on < account_date
          "Invoice #{invoice_reference} is overdue and remains outstanding."
        else
          "Invoice #{invoice_reference} remains outstanding."
        end
      else
        raise Unanswerable, "The invoice status cannot be answered safely."
      end
      rendered("Invoice payment status", body)
    end

    def render_outstanding_amount
      case invoice.status
      when "paid"
        return rendered(
          "Invoice outstanding amount",
          "Invoice #{invoice_reference} is paid and has no outstanding balance."
        )
      when "void"
        return rendered(
          "Invoice outstanding amount",
          "Invoice #{invoice_reference} is void and has no outstanding balance."
        )
      when "uncollectible"
        return rendered(
          "Invoice outstanding amount",
          "Invoice #{invoice_reference} is no longer being collected."
        )
      when "open"
        amount = normalized_amount
        raise Unanswerable, "The outstanding amount is unavailable." if amount.nil?
        if amount <= 0
          return rendered(
            "Invoice outstanding amount",
            "Invoice #{invoice_reference} has no outstanding balance."
          )
        end
      else
        raise Unanswerable, "The outstanding amount cannot be answered safely."
      end

      currency = invoice.currency.to_s.strip.upcase
      unless currency.match?(/\A[A-Z]{3}\z/)
        raise Unanswerable, "The outstanding currency is unavailable."
      end
      rendered(
        "Invoice outstanding amount",
        "The outstanding amount for invoice #{invoice_reference} is " \
          "#{currency} #{ActiveSupport::NumberHelper.number_to_delimited(
            format("%.2f", amount)
          )}."
      )
    end

    def recipient_update_body
      email = outcome["email"] || definition.arguments.fetch("email")
      case outcome["outcome"]
      when "already_primary"
        "#{email} is already the primary recipient for future reminders."
      when "already_present"
        "#{email} is already included on future reminders for this customer."
      when "already_copied"
        "#{email} is already the recipient of this reply, so no duplicate copy was added."
      when "copied"
        "#{email} was copied on this reply only."
      else
        "#{email} was added to future reminder recipients for this customer."
      end
    end

    def safe_invoice_url!
      candidates = [ invoice.online_invoice_url, invoice.invoice_pdf_url ]
      safe = candidates.compact.find { |value| trusted_invoice_url?(value) }
      safe || raise(Unanswerable, "A safe provider invoice link is unavailable.")
    end

    def trusted_invoice_url?(value)
      uri = URI.parse(value.to_s)
      return false unless uri.is_a?(URI::HTTPS)
      return false if uri.userinfo.present? || uri.fragment.present?
      return false unless uri.port == 443

      host = uri.host.to_s.downcase
      return false if literal_ip?(host)

      host.in?(
        TRUSTED_INVOICE_HOSTS.fetch(invoice.invoice_source.provider, [])
      )
    rescue URI::InvalidURIError
      false
    end

    def literal_ip?(host)
      IPAddr.new(host)
      true
    rescue IPAddr::InvalidAddressError
      false
    end

    def rendered(subject, factual_body)
      placeholders = definition.proposed_reply.fetch("placeholders", {})
      body = [
        placeholders["greeting"],
        factual_body,
        placeholders["closing"]
      ].compact_blank.join("\n\n")
      Rendered.new(subject:, body:)
    end

    def normalized_amount
      return if invoice.amount_due.nil?

      invoice.amount_due.to_d
    end

    def invoice_reference
      invoice.number.to_s.strip.presence || invoice.external_id
    end

    def date(value)
      I18n.l(value.to_date, format: :long)
    end

    def account_date
      at.in_time_zone(account_timezone).to_date
    end

    def account_timezone
      account.try(:timezone).presence || Time.zone.name
    end
end

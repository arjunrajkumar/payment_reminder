module CommunicationPreviewsHelper
  INBOX_STATE_PRIORITY = {
    dispute: 1,
    no_reply: 2,
    waiting: 3,
    scheduled: 3,
    monitoring: 4,
    not_contacted: 4,
    paid_up: 5
  }.freeze

  # Temporary named examples used by the UI prototype until communication and
  # collection outcomes are persisted and can feed the normal profile rules.
  DEMO_PAYER_PROFILE_OVERRIDES = {
    "nat dogre" => { key: :new },
    "brightside studio" => { key: :sometimes_late },
    "greenline foods" => { key: :slow_payer },
    "harbor & co" => { key: :unreliable_payer },
    "northstar consulting" => { key: :sometimes_late },
    "pixelcraft labs" => { key: :new },
    "reliable retainer" => { key: :pays_on_time },
    "slow payer co" => { key: :slow_payer }
  }.freeze

  def communication_preview_for(customer)
    return paid_up_communication_preview(customer) if customer.outstanding_invoices.none?

    communication_previews.fetch(customer.name.to_s.squish.downcase) do
      {
        state: :not_contacted,
        status: "Not contacted",
        tone: "slate",
        activity: latest_activity(:no_activity),
        summary: default_payment_summary(customer),
        timestamp: nil,
        needs_attention: customer.overdue_invoices.any?,
        contact_email: customer.email
      }
    end
  end

  def customer_inbox_customers(customers)
    customers.sort_by { |customer| customer_inbox_sort_key(customer) }
  end

  def communication_contact_email(customer)
    customer.email.presence || communication_preview_for(customer).fetch(:contact_email, nil)
  end

  def payer_profile_for(customer)
    override = DEMO_PAYER_PROFILE_OVERRIDES[customer.name.to_s.squish.downcase]
    Customers::PayerProfile.new(customer, override: override).to_h
  end

  def collection_status_for(customer, preview: communication_preview_for(customer))
    Customers::CollectionStatus.new(
      customer,
      collection_state: preview.fetch(:state),
      needs_attention: preview.fetch(:needs_attention)
    ).to_h
  end

  def communication_thread_for(customer)
    preview = communication_preview_for(customer)
    invoice = customer.next_expected_invoice
    invoice_number = invoice&.number.presence || invoice&.external_id || "the open invoice"

    return paid_up_thread(customer) if preview.fetch(:state) == :paid_up
    return nat_dogre_thread(invoice_number) if customer.name.casecmp?("Nat Dogre")
    return reliable_retainer_thread(invoice_number) if customer.name.casecmp?("Reliable Retainer")
    return brightside_thread(invoice_number) if customer.name.casecmp?("Brightside Studio")
    return [] if preview.fetch(:state) == :not_contacted

    event_kind = communication_event_kind(preview.fetch(:state))

    [
      {
        kind: :system,
        label: "Invoice shared",
        timestamp: "Jul 3, 9:12 AM",
        body: "#{invoice_number} was emailed to #{communication_contact_email(customer) || "the billing contact"}."
      },
      {
        kind: event_kind,
        label: preview.fetch(:event_label, communication_event_label(event_kind, customer.name)),
        timestamp: preview.fetch(:timestamp) || "Current",
        body: preview.fetch(:thread_body, preview.fetch(:activity).description)
      }
    ]
  end

  private
    def customer_inbox_sort_key(customer)
      preview = communication_preview_for(customer)

      [
        customer_inbox_state_priority(customer, preview),
        customer.overdue_invoices.any? ? 0 : 1,
        -customer.oldest_overdue_days.to_i,
        customer.name.downcase
      ]
    end

    def customer_inbox_state_priority(customer, preview)
      state = preview.fetch(:state)
      return INBOX_STATE_PRIORITY.fetch(:monitoring) if state == :no_reply && customer.overdue_invoices.none?

      INBOX_STATE_PRIORITY.fetch(state, 4)
    end

    def paid_up_communication_preview(customer)
      {
        state: :paid_up,
        status: "Paid up",
        tone: "slate",
        activity: latest_activity(:payment_received, description: payment_received_description(customer)),
        summary: "#{payment_received_description(customer)}. No follow-up needed.",
        timestamp: customer.last_payment_on&.strftime("%b %-d"),
        needs_attention: false,
        contact_email: customer.email
      }
    end

    def communication_event_kind(state)
      case state
      when :waiting then :outgoing
      when :scheduled then :scheduled
      when :no_reply, :monitoring, :not_contacted, :paid_up then :system
      else :incoming
      end
    end

    def communication_event_label(kind, customer_name)
      case kind
      when :outgoing then "You replied"
      when :scheduled then "Scheduled message"
      when :system then "Collection activity"
      else customer_name
      end
    end

    def communication_previews
      {
        "nat dogre" => {
          state: :waiting,
          status: "Awaiting customer",
          tone: "green",
          activity: latest_activity(:we_replied, description: "Sent the requested payment details"),
          summary: "Customer says payment is being processed. We sent the requested payment details and will follow up in 3 days if unpaid.",
          timestamp: "24 min ago",
          needs_attention: false,
          contact_email: "accounts@natdogre.example"
        },
        "brightside studio" => {
          state: :dispute,
          status: "Dispute raised",
          tone: "red",
          activity: latest_activity(:customer_replied),
          summary: "Customer disputes the phase-two amount. Review it with the project owner before asking for payment.",
          timestamp: "1 hr ago",
          needs_attention: true,
          contact_email: "billing@brightsidestudio.example"
        },
        "greenline foods" => {
          state: :waiting,
          status: "Awaiting customer",
          tone: "green",
          activity: latest_activity(:we_replied),
          summary: "We sent the requested line-item breakdown. Waiting for their reply.",
          thread_body: "Thanks for checking on this. We sent the line-item breakdown for the invoice and highlighted how the outstanding balance was calculated. Please reply if any line still needs clarification.",
          timestamp: "2 hr ago",
          needs_attention: false,
          contact_email: "ap@greenlinefoods.example"
        },
        "northstar consulting" => {
          state: :scheduled,
          status: "Scheduled",
          tone: "blue",
          activity: latest_activity(:scheduled),
          summary: "A reminder will send tomorrow at 9:00 AM if the invoice is still unpaid.",
          timestamp: "Tomorrow, 9:00 AM",
          needs_attention: false,
          contact_email: "finance@northstar.example"
        },
        "harbor & co" => {
          state: :no_reply,
          status: "No reply",
          tone: "amber",
          activity: latest_activity(:reminder_opened),
          summary: "No reply after three reminders. Escalate to a person.",
          timestamp: "6 days ago",
          needs_attention: true,
          contact_email: "accounts@harborco.example"
        },
        "slow payer co" => {
          state: :monitoring,
          status: "Monitoring",
          tone: "slate",
          activity: latest_activity(:no_activity, description: "Payment is expected Jul 15 based on their usual timing"),
          summary: "Payment is 12 days overdue, but this matches their usual timing. We will check for payment Jul 15.",
          timestamp: nil,
          needs_attention: false,
          contact_email: "billing@slowpayer.example"
        },
        "reliable retainer" => {
          state: :waiting,
          status: "Awaiting payment",
          tone: "green",
          activity: latest_activity(:we_replied, description: "Thanked them for confirming payment Tuesday"),
          summary: "Customer promises to pay Tuesday. We will follow up Wednesday if it is still unpaid.",
          timestamp: "18 min ago",
          needs_attention: false,
          contact_email: "billing@reliableretainer.example"
        },
        "pixelcraft labs" => {
          state: :no_reply,
          status: "No reply",
          tone: "amber",
          activity: latest_activity(:reminder_opened),
          summary: "No reply after three reminders, but the invoice is not due for 12 days. No further action today.",
          timestamp: "Yesterday",
          needs_attention: false,
          contact_email: "accounts@pixelcraft.example"
        }
      }
    end

    def default_payment_summary(customer)
      invoice = customer.next_expected_invoice
      return "No collection conversation yet. Review the open balance." unless invoice

      due_context = customer_invoice_due_context(invoice, as_of: customer.as_of).downcase
      if invoice.due_on && invoice.due_on < customer.as_of
        "No collection conversation yet. The invoice is #{due_context}; send a reminder."
      else
        "No collection conversation yet. The invoice is #{due_context}; no action is needed today."
      end
    end

    def latest_activity(kind, description: nil)
      Customers::LatestActivity.new(kind: kind, description: description)
    end

    def payment_received_description(customer)
      payment = customer.paid_invoices.max_by { |invoice| invoice.paid_on || Date.new(1, 1, 1) }
      return "Payment recorded; balance paid in full" unless payment

      paid_amount = payment.amount_paid.to_d.positive? ? payment.amount_paid : payment.total
      amount = receivable_amount(paid_amount, payment.currency)
      "#{amount} received; balance paid in full"
    end

    def nat_dogre_thread(invoice_number)
      [
        {
          kind: :system,
          label: "Invoice shared",
          timestamp: "Jul 3, 9:12 AM",
          body: "#{invoice_number} was emailed to accounts@natdogre.example."
        },
        {
          kind: :incoming,
          label: "Nat Dogre",
          timestamp: "28 min ago",
          body: "Payment is being processed. Can you confirm the bank details we should use?"
        },
        {
          kind: :outgoing,
          label: "Payment details sent",
          timestamp: "24 min ago",
          body: "We sent the bank details for this payment and asked them to confirm once it is scheduled."
        },
        {
          kind: :scheduled,
          label: "Automatic follow-up",
          timestamp: "Jul 16",
          body: "If neither a reply nor payment arrives, PaymentReminder will send a follow-up."
        }
      ]
    end

    def reliable_retainer_thread(invoice_number)
      [
        {
          kind: :system,
          label: "Invoice sent",
          timestamp: "Jul 3, 9:12 AM",
          body: "#{invoice_number} was delivered to billing@reliableretainer.example."
        },
        {
          kind: :incoming,
          label: "Reliable Retainer",
          timestamp: "22 min ago",
          body: "I am travelling today, but I will clear the payment on Tuesday."
        },
        {
          kind: :outgoing,
          label: "Payment date acknowledged",
          timestamp: "18 min ago",
          body: "Thanks for letting us know. We will look out for the payment on Tuesday."
        },
        {
          kind: :scheduled,
          label: "Automatic follow-up",
          timestamp: "Wednesday, 9:00 AM",
          body: "If payment has not arrived, PaymentReminder will send a short follow-up."
        }
      ]
    end

    def paid_up_thread(customer)
      [
        {
          kind: :system,
          label: "Account paid up",
          timestamp: customer.last_payment_on ? customer.last_payment_on.strftime("%b %-d, %Y") : "Recorded payment history",
          body: "No open balance remains, so no collection follow-up is needed."
        }
      ]
    end

    def brightside_thread(invoice_number)
      [
        {
          kind: :system,
          label: "Invoice sent",
          timestamp: "Jun 1, 9:12 AM",
          body: "#{invoice_number} was delivered to billing@brightsidestudio.example."
        },
        {
          kind: :incoming,
          label: "Brightside Studio",
          timestamp: "1 hr ago",
          body: "This amount does not match the scope we agreed for phase two."
        },
        {
          kind: :outgoing,
          label: "Automatic acknowledgement",
          timestamp: "55 min ago",
          body: "Thanks for flagging this. We have paused payment reminders while our team checks the phase-two scope. We will reply with a clear breakdown before any further collection follow-up."
        }
      ]
    end
end

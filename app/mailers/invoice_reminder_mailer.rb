class InvoiceReminderMailer < ApplicationMailer
  def reminder(invoice, stage)
    prepare_reminder(invoice, stage)

    mail(
      to: @customer.reminder_email_addresses,
      from: email_address_with_name(
        @account.invoice_reminder_from_email,
        @account.invoice_reminder_from_name.presence || @account.name
      ),
      subject: reminder_subject
    )
  end

  private
    def prepare_reminder(invoice, stage)
      @invoice = invoice
      @stage = stage
      @account = invoice.account
      @customer = invoice.customer
      @invoice_reference = invoice.number.presence || invoice.external_id
      @invoice_date = formatted_date(invoice.issued_on)
      @due_date = formatted_date(invoice.due_on)
      @amount_due = formatted_amount_due
      @online_invoice_url = invoice.online_invoice_url
      @heading = reminder_heading
      @message = reminder_message
    end

    def reminder_subject
      if @stage.tone_final?
        "URGENT: Invoice #{@invoice_reference} - Immediate Action Required"
      elsif @stage.category_pre_due?
        "Upcoming Payment Due: Invoice #{@invoice_reference}"
      elsif @stage.tone_firm?
        "Payment Overdue: Invoice #{@invoice_reference}"
      else
        "Payment Reminder: Invoice #{@invoice_reference}"
      end
    end

    def reminder_heading
      return pre_due_heading if @stage.category_pre_due?

      case @stage.tone.to_sym
      when :friendly
        "A friendly payment reminder"
      when :neutral
        "Payment reminder"
      when :direct
        "Payment is due"
      when :firm
        "Payment is overdue"
      when :final
        "Final payment reminder"
      end
    end

    def pre_due_heading
      case @stage.tone.to_sym
      when :friendly
        "A friendly payment reminder"
      when :neutral
        "Upcoming payment reminder"
      when :direct, :firm
        "Payment is due soon"
      when :final
        "Final notice before payment is due"
      end
    end

    def reminder_message
      @stage.category_pre_due? ? pre_due_message : overdue_message
    end

    def pre_due_message
      case @stage.tone.to_sym
      when :friendly
        "This is a friendly reminder that invoice #{@invoice_reference} is due in #{day_label}, on #{@due_date}."
      when :neutral
        "This is a reminder that invoice #{@invoice_reference} is due in #{day_label}, on #{@due_date}."
      when :direct
        "Invoice #{@invoice_reference} is due in #{day_label}, on #{@due_date}. Please arrange payment by the due date."
      when :firm
        "Invoice #{@invoice_reference} is due in #{day_label}, on #{@due_date}. Please ensure payment is made on time."
      when :final
        "Invoice #{@invoice_reference} is due in #{day_label}, on #{@due_date}. Please treat this as a final notice before the due date."
      end
    end

    def overdue_message
      case @stage.tone.to_sym
      when :friendly
        "This is a friendly reminder that invoice #{@invoice_reference} is #{overdue_day_label}. Please arrange payment when you can."
      when :neutral
        "This is a reminder that invoice #{@invoice_reference} is #{overdue_day_label}. Please arrange payment as soon as possible."
      when :direct
        "Invoice #{@invoice_reference} is #{overdue_day_label}. Please arrange payment as soon as possible."
      when :firm
        "Payment for invoice #{@invoice_reference} is #{overdue_day_label}. Please arrange payment immediately or contact us if there is a problem."
      when :final
        "This is a final reminder that invoice #{@invoice_reference} is #{overdue_day_label}. Immediate payment is required."
      end
    end

    def day_label
      "#{@stage.day_offset} #{@stage.day_offset == 1 ? "day" : "days"}"
    end

    def overdue_day_label
      "#{day_label} overdue"
    end

    def formatted_date(date)
      date.present? ? I18n.l(date, format: :long) : "Not available"
    end

    def formatted_amount_due
      return "Amount unavailable" if @invoice.amount_due.nil? || @invoice.currency.blank?

      amount = BigDecimal(@invoice.amount_due.to_s)
      precision = amount.frac.zero? ? 0 : 2

      ActiveSupport::NumberHelper.number_to_currency(
        amount,
        unit: "#{@invoice.currency.upcase} ",
        format: "%u%n",
        precision:
      )
    end
end

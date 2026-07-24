class InvoiceReminderNotificationMailer < ApplicationMailer
  def reminder_sent(user, invoice, reminder, terminal: false, recipient_email: nil)
    prepare_notification(user, invoice, reminder)
    @terminal = terminal

    mail(
      to: recipient_email || @user.identity.email_address,
      subject: reminder_subject
    )
  end

  def manual_follow_up(user, invoice, reminder, recipient_email: nil)
    prepare_notification(user, invoice, reminder)
    @days_overdue = @reminder.day_offset

    mail(
      to: recipient_email || @user.identity.email_address,
      subject: "Final Reminder Sent for Invoice #{@invoice_reference} - Manual Follow-up Required"
    )
  end

  private
    def prepare_notification(user, invoice, reminder)
      @user = user
      @invoice = invoice
      @reminder = reminder
      @invoice_reference = @invoice.number.presence || @invoice.external_id
      @customer_name = @invoice.customer&.name.presence || @invoice.contact_name.presence || "Customer"
      @due_date = @invoice.due_on.present? ? I18n.l(@invoice.due_on, format: :long) : "Not available"
      @outstanding_amount = formatted_outstanding_amount
      @stage = stage_label
    end

    def reminder_subject
      if @terminal
        "URGENT: Invoice #{@invoice_reference} - Immediate Action Required"
      elsif @reminder.category_pre_due?
        "Upcoming Payment Due: Invoice #{@invoice_reference}"
      elsif @reminder.day_offset <= 1
        "Payment Reminder: Invoice #{@invoice_reference}"
      else
        "Payment Overdue: Invoice #{@invoice_reference}"
      end
    end

    def formatted_outstanding_amount
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

    def stage_label
      days = @reminder.day_offset
      day_label = "#{days} #{days == 1 ? "day" : "days"}"

      if @reminder.category_pre_due?
        "Pre-due — #{day_label} before due"
      else
        "Overdue — #{day_label} overdue"
      end
    end
end

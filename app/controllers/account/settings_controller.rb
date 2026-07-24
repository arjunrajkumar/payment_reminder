class Account::SettingsController < ApplicationController
  require_account_admin only: :update

  before_action :set_account
  before_action :set_xero_invoice_source
  before_action :set_invoice_sources
  before_action :set_customer_segments
  before_action :set_notification_preferences
  before_action :set_email_connection
  before_action :set_conversation_ai_health

  def show; end

  def update
    attributes = account_params

    if @account.update(attributes)
      redirect_to account_settings_path(script_name: @account.slug),
        notice: update_notice(attributes)
    else
      flash.delete(:notice)
      flash.now[:alert] = @account.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  private
    def set_account
      @account = Current.account
    end

    def set_invoice_sources
      @invoice_sources = InvoiceSource.available_sources_for(@account)
    end

    def set_xero_invoice_source
      @xero_invoice_source = @account.invoice_sources.xero.first
    end

    def set_customer_segments
      @customer_segments = @account.customer_segments.index_by(&:payer_segment)
    end

    def set_notification_preferences
      @notification_preferences = Current.user.notification_subscriptions.index_by(&:event)
    end

    def account_params
      params.expect(account: [
        :automatic_invoice_reminders_enabled,
        :invoice_reminder_from_name,
        customer_segments_attributes: {
          good_debtor: %i[id on_time_rate],
          bad_debtor: %i[id on_time_rate]
        }
      ])
    end

    def update_notice(attributes)
      if attributes.key?(:automatic_invoice_reminders_enabled) || attributes.key?(:invoice_reminder_from_name)
        "Invoice reminder settings saved."
      else
        "Debtor rating rules saved. Refresh ratings to apply them."
      end
    end

    def set_email_connection
      @email_connection = @account.email_connection
    end

    def set_conversation_ai_health
      @conversation_ai_health = ConversationAi::Health.call(account: @account)
    end
end

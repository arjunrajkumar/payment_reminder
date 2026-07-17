class Account::SettingsController < ApplicationController
  before_action :set_account
  before_action :set_invoice_sources
  before_action :set_customer_segments
  before_action :set_notification_preferences

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

    def set_customer_segments
      @customer_segments = @account.customer_segments.index_by(&:payer_segment)
    end

    def set_notification_preferences
      notification_user = @account.users.active.find_by!(identity: Current.identity)
      @notification_preferences = notification_user.notification_subscriptions.index_by(&:event)
    end

    def account_params
      params.expect(account: [
        :automatic_invoice_reminders_enabled,
        customer_segments_attributes: {
          good_debtor: %i[id on_time_rate],
          bad_debtor: %i[id on_time_rate]
        }
      ])
    end

    def update_notice(attributes)
      if attributes.key?(:automatic_invoice_reminders_enabled)
        "Invoice reminder settings saved."
      else
        "Debtor rating rules saved. Refresh ratings to apply them."
      end
    end
end

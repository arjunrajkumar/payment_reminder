class Account::SettingsController < ApplicationController
  before_action :set_account
  before_action :set_invoice_sources
  before_action :set_customer_segments

  def show; end

  def update
    if @account.update(account_params)
      redirect_to account_settings_path(script_name: @account.slug),
        notice: "Debtor rating rules saved. Refresh ratings to apply them."
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

    def account_params
      params.expect(account: [
        customer_segments_attributes: {
          good_debtor: %i[id on_time_rate],
          bad_debtor: %i[id on_time_rate]
        }
      ])
    end
end

class InvoicesController < ApplicationController
  def index
    @xero_integration = Current.account.accounting_integrations.xero.connected.first
    set_page_and_extract_portion_from Current.account.invoices.includes(:accounting_integration).recent
  end
end

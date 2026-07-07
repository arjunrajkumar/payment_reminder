class InvoicesController < ApplicationController
  before_action :set_invoice_sources

  def index
    set_page_and_extract_portion_from Current.account.invoices.includes(:invoice_source).recent
  end

  private

  def set_invoice_sources
    @invoice_sources = InvoiceSource.connected_for(Current.account)
    redirect_to invoice_sources_path if @invoice_sources.none?
  end
end

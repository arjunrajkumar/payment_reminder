class InvoicesController < ApplicationController
  def index
    @as_of = Date.current
    @invoice_sources = InvoiceSource.connected_for(Current.account)
    @has_invoices = Current.account.invoices.exists?
    @invoices = set_page_and_extract_portion_from(
      Current.account.invoices.for_index(as_of: @as_of)
    ).load
  end
end

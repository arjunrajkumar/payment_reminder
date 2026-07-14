class ReceivablesController < ApplicationController
  def index
    @invoice_sources = InvoiceSource.connected_for(Current.account)
    @has_synced_invoices = Current.account.invoices.exists?
    @as_of = Date.current
    @inbox_customers = Current.account.customers
      .with_issued_invoices
      .preload(:issued_invoices)
      .order(:name)
      .to_a
  end
end

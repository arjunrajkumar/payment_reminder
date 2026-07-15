class ReceivablesController < ApplicationController
  def index
    @invoice_sources = InvoiceSource.connected_for(Current.account)

    @receivables = set_page_and_extract_portion_from(
      Current.account.receivables.for_inbox
    ).load
  end
end

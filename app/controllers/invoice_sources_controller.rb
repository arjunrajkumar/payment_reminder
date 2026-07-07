class InvoiceSourcesController < ApplicationController
  def index
    @invoice_sources = InvoiceSource.available_sources_for(Current.account)
  end
end

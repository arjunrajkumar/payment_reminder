class CustomersController < ApplicationController
  def show
    @customer = Current.account.customers
      .with_issued_invoices
      .preload(:issued_invoices)
      .find(params[:id])
  end
end

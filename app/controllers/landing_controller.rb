class LandingController < ApplicationController
  allow_unauthenticated_access

  def index
    if Current.account
      redirect_to invoices_path
    else
      redirect_to "https://www.paymentreminderemails.com", allow_other_host: true
    end
  end
end

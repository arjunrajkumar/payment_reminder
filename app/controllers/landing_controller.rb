class LandingController < ApplicationController
  allow_unauthenticated_access

  def index
    redirect_to invoices_path if Current.account
  end
end

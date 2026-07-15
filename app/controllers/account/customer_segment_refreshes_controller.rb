class Account::CustomerSegmentRefreshesController < ApplicationController
  def create
    Current.account.refresh_payer_segments!

    redirect_to account_settings_path(script_name: Current.account.slug),
      notice: "Customer segments refreshed."
  end
end

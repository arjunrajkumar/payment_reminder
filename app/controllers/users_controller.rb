class UsersController < ApplicationController
  before_action :set_user
  before_action :ensure_permission_to_change_user

  def destroy
    @user.deactivate

    respond_to do |format|
      format.html { redirect_to account_settings_path }
      format.json { head :no_content }
    end
  end

  private
    def set_user
      @user = Current.account.users.active.find(params[:id])
    end

    def ensure_permission_to_change_user
      head :forbidden unless Current.user.can_change?(@user)
    end
end

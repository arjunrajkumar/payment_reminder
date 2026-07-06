class SessionsController < ApplicationController
  def destroy
    terminate_session

    respond_to do |format|
      format.html { redirect_to root_path, notice: "Signed out." }
      format.json { head :no_content }
    end
  end
end

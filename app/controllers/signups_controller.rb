class SignupsController < ApplicationController
  wrap_parameters :signup, include: %i[email_address]

  allow_unauthenticated_access
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_signup_path, alert: "Try again later." }
  before_action :redirect_authenticated_user

  layout "public"

  def new
    @signup = Signup.new
  end

  def create
    signup = Signup.new(signup_params)

    if signup.valid?(:identity_creation)
      redirect_to_session_magic_link signup.create_identity
    else
      head :unprocessable_entity
    end
  end

  private
    def redirect_authenticated_user
      if Current.user.present?
        redirect_to root_path
      elsif authenticated?
        redirect_to new_signup_completion_path
      end
    end

    def signup_params
      params.expect(signup: :email_address)
    end
end

class Signups::CompletionsController < ApplicationController
  wrap_parameters :signup, include: %i[full_name]

  before_action :ensure_authenticated_identity
  before_action :redirect_completed_signup

  layout "public"

  def new
    @signup = Signup.new(identity: Current.identity)
  end

  def create
    @signup = Signup.new(signup_params)

    if @signup.complete
      welcome_to_account
    else
      invalid_signup
    end
  end

  private
    def ensure_authenticated_identity
      redirect_to new_signup_path, alert: "Enter your email address to sign up." unless Current.identity.present?
    end

    def redirect_completed_signup
      redirect_to root_path if Current.user.present?
    end

    def signup_params
      params.expect(signup: %i[full_name]).with_defaults(identity: Current.identity)
    end

    def welcome_to_account
      respond_to do |format|
        format.html { redirect_to account_settings_url(script_name: @signup.account.slug), notice: "Welcome to PaidJar." }
        format.json { head :created }
      end
    end

    def invalid_signup
      respond_to do |format|
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: { errors: @signup.errors.full_messages }, status: :unprocessable_entity }
      end
    end
end

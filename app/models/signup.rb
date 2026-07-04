class Signup
  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Validations

  attr_accessor :full_name, :email_address, :identity
  attr_reader :account, :user

  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }, on: :identity_creation
  validates :full_name, :identity, presence: true, on: :completion
  validates :full_name, length: { maximum: 240 }

  def initialize(...)
    super

    @email_address = @identity.email_address if @identity
  end

  def email_address=(value)
    @email_address = value.to_s.strip.downcase.presence
  end

  def create_identity
    @identity = Identity.find_or_create_by!(email_address: email_address)
    @identity.send_magic_link for: :sign_up
  end

  def complete
    if valid?(:completion)
      create_account
      true
    else
      false
    end
  rescue => error
    destroy_account
    errors.add(:base, "Something went wrong, and we couldn't create your account. Please give it another try.")
    Rails.error.report(error, severity: :error)
    false
  end

  private
    def create_account
      @account = Account.create_with_owner(
        account: {
          name: generate_account_name
        },
        owner: {
          name: full_name,
          identity: identity
        }
      )
      @user = @account.users.find_by!(role: :owner)
    end

    def generate_account_name
      Signup::AccountNameGenerator.new(identity: identity, name: full_name).generate
    end

    def destroy_account
      @account&.destroy!
      @user = nil
      @account = nil
    end
end

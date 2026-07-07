require "test_helper"

class LandingControllerTest < ActionDispatch::IntegrationTest
  test "root redirects signed out users to the marketing site" do
    get root_url

    assert_redirected_to "https://www.paidjar.com"
  end

  test "home redirects signed out users to the marketing site" do
    get home_url

    assert_redirected_to "https://www.paidjar.com"
  end

  test "root redirects signed in accounts to invoices" do
    sign_up_and_complete

    get root_url

    assert_redirected_to invoices_url
  end

  private
    def sign_up_and_complete(email_address: "owner-landing@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

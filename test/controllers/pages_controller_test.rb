require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "privacy policy is public" do
    get privacy_url

    assert_response :success
    assert_select "title", text: "Privacy Policy | PaymentReminder"
    assert_select "h1", text: "PaymentReminder Privacy Policy"
    assert_select "a[href='#{terms_path}']", text: "Terms of Service"
  end

  test "terms of service is public" do
    get terms_url

    assert_response :success
    assert_select "title", text: "Terms of Service | PaymentReminder"
    assert_select "h1", text: "PaymentReminder Terms of Service"
    assert_select "a[href='#{privacy_path}']", text: "Privacy Policy"
  end

  test "legal pages remain public when signed in" do
    post signup_url, params: { signup: { email_address: "legal-owner@example.com" } }
    post session_magic_link_url, params: { code: MagicLink.last.code }

    get privacy_url

    assert_response :success
  end
end

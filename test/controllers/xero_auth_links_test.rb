require "test_helper"

class XeroAuthLinksTest < ActionDispatch::IntegrationTest
  test "email signup remains available alongside Xero signup" do
    get new_signup_url

    assert_response :success
    assert_select ".auth-xero-provider[data-turbo=false] [data-xero-sso][data-href=?][data-label='Sign up with Xero']", new_xero_signup_path
    assert_select "script[src='https://edge.xero.com/platform/sso/xero-sso.js']"
    assert_select "input[type=email][name='signup[email_address]']"
  end

  test "email sign-in remains available alongside Xero sign-in" do
    get new_session_url

    assert_response :success
    assert_select ".auth-xero-provider[data-turbo=false] [data-xero-sso][data-href=?][data-label='Sign in with Xero']", new_xero_session_path
    assert_select "script[src='https://edge.xero.com/platform/sso/xero-sso.js']"
    assert_select "input[type=email][name='email_address']"
  end
end

require "test_helper"

class Account::CustomerSegmentRefreshesControllerTest < ActionDispatch::IntegrationTest
  test "create requires a PaymentReminder session" do
    post account_customer_segment_refresh_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "create refreshes customer segments for the current account" do
    account = sign_up_and_complete
    Account.any_instance.expects(:refresh_customer_segments!).once

    post account_customer_segment_refresh_url(script_name: account.slug)

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Debtor ratings refreshed.", flash[:notice]
  end

  private
    def sign_up_and_complete(email_address: "owner-segment-refresh@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

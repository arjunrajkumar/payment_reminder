require "test_helper"

class Account::SettingsControllerTest < ActionDispatch::IntegrationTest
  test "show renders simplified account settings" do
    account = sign_up_and_complete

    get account_settings_url(script_name: account.slug)

    assert_response :success
    assert_select "h1", "Settings"
    assert_select "#nav a[aria-current='page']", "Settings"
    assert_select ".app-card__title", "Business profile"
    assert_select ".app-field", account.name
    assert_select ".app-field", count: 1
    assert_select "body", { text: "owner-settings@example.com", count: 0 }
    assert_select "body", { text: "Billing email", count: 0 }
    assert_select "body", { text: "Currency", count: 0 }
    assert_select ".app-card__title", "Accounting integration"
    assert_select "a[href=?]", new_xero_connection_path, "Connect"
    assert_select "a[href=?]", new_stripe_connection_path, "Connect"
    assert_select ".app-card", count: 2
    assert_select "section", { text: "Reminder cadence", count: 0 }
    assert_select "section", { text: "Notifications", count: 0 }
    assert_select "form[action=?]", session_path(script_name: nil) do
      assert_select "button", "Sign out"
    end
  end

  test "connected invoice sources can be resynced" do
    account = sign_up_and_complete(email_address: "owner-settings-resync@example.com")
    source = account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "tenant-settings-resync",
      external_account_name: "PaymentReminder Xero",
      access_token: "access-token",
      refresh_token: "refresh-token",
      expires_at: 30.minutes.from_now
    )

    get account_settings_url(script_name: account.slug)

    assert_response :success
    assert_select ".app-pill", "Connected"
    assert_select "form[action=?]", invoice_source_refresh_path(source) do
      assert_select "button", "Resync"
    end
  end

  test "sign out clears session" do
    account = sign_up_and_complete

    delete session_url(script_name: nil)

    assert_redirected_to new_session_url

    get account_settings_url(script_name: account.slug)

    assert_redirected_to new_session_url(script_name: nil)
  end

  private
    def sign_up_and_complete(email_address: "owner-settings@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

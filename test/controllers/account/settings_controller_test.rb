require "test_helper"

class Account::SettingsControllerTest < ActionDispatch::IntegrationTest
  test "show renders account settings dashboard" do
    account = sign_up_and_complete

    get account_settings_url(script_name: account.slug)

    assert_response :success
    assert_select "h1", "Settings"
    assert_select "#nav a[aria-current='page']", "Settings"
    assert_select ".app-card__title", "Business profile"
    assert_select ".app-field", account.name
    assert_select ".app-field", "owner-settings@example.com"
    assert_select ".app-card__title", "Accounting integration"
    assert_select ".app-card__title", "Reminder cadence"
    assert_select ".app-card__title", "Notifications"
    assert_select "section", { text: "People on this account", count: 0 }
    assert_select "button", text: /Sign out/, count: 0
  end

  test "owner updates account name" do
    account = sign_up_and_complete

    patch account_settings_url(script_name: account.slug), params: { account: { name: "Updated PaymentReminder" } }

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Updated PaymentReminder", account.reload.name
  end

  test "show renders account and users as json" do
    account = sign_up_and_complete(email_address: "json-settings@example.com")

    get account_settings_url(script_name: account.slug, format: :json)

    body = JSON.parse(response.body)

    assert_response :success
    assert_equal account.id, body.dig("account", "id")
    assert_equal account.name, body.dig("account", "name")
    assert_equal account.slug, body.dig("account", "slug")
    assert_equal [ "json-settings@example.com" ], body.fetch("users").map { |user| user.fetch("email_address") }
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

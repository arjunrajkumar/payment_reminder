require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "new renders sign in form" do
    get new_session_url

    assert_response :success
    assert_select "h1", "Sign in"
    assert_select "input[type=email][name='email_address']"
  end

  test "create sends sign in code for an existing identity" do
    account = sign_up_and_complete(email_address: "returning@example.com")
    delete session_url(script_name: nil)

    assert_difference -> { MagicLink.count }, 1 do
      post session_url, params: { email_address: " Returning@Example.com " }
    end

    assert_redirected_to session_magic_link_url
    assert_equal account.users.owner.first.identity, MagicLink.last.identity
    assert_predicate MagicLink.last, :for_sign_in?
  end

  test "magic link code submission uses a full-page request" do
    account = sign_up_and_complete(email_address: "full-page-code@example.com")
    identity = account.users.owner.first.identity
    delete session_url(script_name: nil)

    post session_url(script_name: nil), params: { email_address: identity.email_address }
    follow_redirect!

    assert_select "form[action='#{session_magic_link_path}'][data-turbo='false']"
  end

  test "create redirects unknown email addresses back to sign in" do
    assert_no_difference -> { Identity.count } do
      assert_no_difference -> { MagicLink.count } do
        post session_url, params: { email_address: "unknown@example.com" }
      end
    end

    assert_redirected_to new_session_url
  end

  test "account-scoped sign in redirects to the global sign in page" do
    account = sign_up_and_complete(email_address: "scoped-session@example.com")
    delete session_url(script_name: nil)

    get new_session_url(script_name: account.slug)

    assert_redirected_to new_session_url(script_name: nil)
    assert_response :see_other
  end

  test "account-scoped magic link redirects to the global magic link page" do
    account = sign_up_and_complete(email_address: "scoped-code@example.com")
    delete session_url(script_name: nil)

    get session_magic_link_url(script_name: account.slug)

    assert_redirected_to session_magic_link_url(script_name: nil)
    assert_response :see_other
  end

  test "sign out then sign back in" do
    account = sign_up_and_complete(email_address: "again@example.com")
    identity = account.users.owner.first.identity

    delete session_url(script_name: nil)
    assert_redirected_to new_session_url
    assert_not cookies[:session_token].present?

    post session_url(script_name: nil), params: { email_address: identity.email_address }
    post session_magic_link_url, params: { code: MagicLink.last.code }

    assert_redirected_to root_url
    assert cookies[:session_token].present?
  end

  test "signing in after an account-scoped redirect returns to the requested page" do
    account = sign_up_and_complete(email_address: "return-to@example.com")
    identity = account.users.owner.first.identity

    delete session_url(script_name: nil)
    get account_settings_url(script_name: account.slug)

    assert_redirected_to new_session_url(script_name: nil)

    post session_url(script_name: nil), params: { email_address: identity.email_address }
    post session_magic_link_url, params: { code: MagicLink.last.code }

    assert_redirected_to account_settings_url(script_name: account.slug)
  end

  test "destroy via json clears session" do
    sign_up_and_complete

    delete session_url(script_name: nil, format: :json)

    assert_response :no_content
    assert_not cookies[:session_token].present?
  end

  private
    def sign_up_and_complete(email_address: "owner-session@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

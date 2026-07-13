require "test_helper"

class SignupsControllerTest < ActionDispatch::IntegrationTest
  test "new renders email signup form" do
    get new_signup_url

    assert_response :success
    assert_select "h1", "Sign up"
    assert_select "input[type=email][name='signup[email_address]']"
  end

  test "create sends signup code and redirects to magic link entry" do
    assert_difference -> { Identity.count }, 1 do
      assert_difference -> { MagicLink.count }, 1 do
        post signup_url, params: { signup: { email_address: " New@Example.COM " } }
      end
    end

    identity = Identity.last
    magic_link = MagicLink.last

    assert_redirected_to session_magic_link_url
    assert_equal "new@example.com", identity.email_address
    assert_equal identity, magic_link.identity
    assert_predicate magic_link, :for_sign_up?
  end

  test "create returns pending authentication token as json" do
    post signup_url(format: :json), params: { signup: { email_address: "json@example.com" } }

    assert_response :created
    assert JSON.parse(response.body).fetch("pending_authentication_token").present?
  end

  test "completes signup after verification code" do
    post signup_url, params: { signup: { email_address: "owner@example.com" } }

    magic_link = MagicLink.last

    post session_magic_link_url, params: { code: magic_link.code }

    assert_redirected_to new_signup_completion_url

    assert_difference -> { Account.count }, 1 do
      assert_difference -> { User.count }, 2 do
        post signup_completion_url, params: { signup: { full_name: "Owner Person" } }
      end
    end

    user = magic_link.identity.users.owner.first

    assert_redirected_to account_settings_url(script_name: user.account.slug)
    assert_equal "Owner Person", user.name
    assert_equal "owner@example.com", user.identity.email_address
    assert_equal "Owner's PaymentReminder", user.account.name
    assert_equal magic_link.identity, user.identity
    assert_predicate user, :owner?
    assert_predicate user.verified_at, :present?
    assert_predicate user.account.users.find_by!(role: :system), :system?
  end

  test "verification code returns session token as json" do
    post signup_url(format: :json), params: { signup: { email_address: "json-code@example.com" } }

    magic_link = MagicLink.last

    post session_magic_link_url(format: :json), params: { code: magic_link.code }

    body = JSON.parse(response.body)

    assert_response :success
    assert body.fetch("session_token").present?
    assert_equal true, body.fetch("requires_signup_completion")
  end

  test "invalid verification code returns json error" do
    post signup_url(format: :json), params: { signup: { email_address: "bad-code@example.com" } }
    post session_magic_link_url(format: :json), params: { code: "BAD123" }

    assert_response :unauthorized
    assert_equal "Try another code.", JSON.parse(response.body).fetch("message")
  end

  test "completion returns json created" do
    post signup_url(format: :json), params: { signup: { email_address: "json-complete@example.com" } }
    post session_magic_link_url(format: :json), params: { code: MagicLink.last.code }

    assert_difference -> { Account.count }, 1 do
      post signup_completion_url(format: :json), params: { signup: { full_name: "Json Complete" } }
    end

    assert_response :created
  end

  test "completion returns json errors" do
    post signup_url(format: :json), params: { signup: { email_address: "json-error@example.com" } }
    post session_magic_link_url(format: :json), params: { code: MagicLink.last.code }

    post signup_completion_url(format: :json), params: { signup: { full_name: "" } }

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).fetch("errors"), "Full name can't be blank"
  end

  test "completed signup redirects away from signup screens" do
    post signup_url, params: { signup: { email_address: "done@example.com" } }
    post session_magic_link_url, params: { code: MagicLink.last.code }
    post signup_completion_url, params: { signup: { full_name: "Done Person" } }

    get new_signup_url
    assert_redirected_to root_url

    get new_signup_completion_url
    assert_redirected_to root_url
  end
end

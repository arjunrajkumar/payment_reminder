require "test_helper"

class Users::RolesControllerTest < ActionDispatch::IntegrationTest
  test "admin changes member role" do
    account = sign_up_and_complete
    member = account.users.create!(name: "Member User", identity: Identity.create!(email_address: "role-member@example.com"), role: :member)

    patch user_role_url(member, script_name: account.slug), params: { user: { role: "admin" } }

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_predicate member.reload, :admin?
  end

  test "admin cannot change owner role" do
    account = sign_up_and_complete
    owner = account.users.owner.first

    patch user_role_url(owner, script_name: account.slug), params: { user: { role: "member" } }

    assert_response :forbidden
    assert_predicate owner.reload, :owner?
  end

  private
    def sign_up_and_complete(email_address: "owner-roles@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  test "admin deactivates member" do
    account = sign_up_and_complete
    member_identity = Identity.create!(email_address: "member@example.com")
    member = account.users.create!(name: "Member User", identity: member_identity, role: :member)

    assert_difference -> { account.users.active.count }, -1 do
      delete user_url(member, script_name: account.slug)
    end

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_not member.reload.active?
    assert_nil member.identity
  end

  test "member cannot deactivate another user" do
    account = sign_up_and_complete
    member_identity = Identity.create!(email_address: "member-permission@example.com")
    member = account.users.create!(name: "Member User", identity: member_identity, role: :member)
    other = account.users.create!(name: "Other User", identity: Identity.create!(email_address: "other@example.com"), role: :member)

    switch_session_to(member_identity)

    delete user_url(other, script_name: account.slug)

    assert_response :forbidden
    assert_predicate other.reload, :active?
  end

  private
    def sign_up_and_complete(email_address: "owner-users@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end

    def switch_session_to(identity)
      delete session_url(script_name: nil)
      magic_link = identity.send_magic_link
      post signup_url, params: { signup: { email_address: identity.email_address } }
      post session_magic_link_url, params: { code: magic_link.code }
    end
end

require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  test "identity selects an active human user instead of the system user" do
    account = Account.create_with_owner(
      account: { name: "Owner Account" },
      owner: { name: "Owner User", identity: Identity.create!(email_address: "owner-current@example.com") }
    )

    Current.identity = account.users.owner.first.identity

    assert_predicate Current.user, :owner?
  ensure
    Current.reset
  end
end

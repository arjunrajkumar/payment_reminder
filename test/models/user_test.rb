require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "belongs to an account" do
    assert_equal accounts(:paid_jar), users(:arjun).account
  end

  test "requires a name" do
    user = accounts(:paid_jar).users.build

    assert_not user.valid?
    assert_includes user.errors[:name], "can't be blank"
  end

  test "filters active human users" do
    inactive = accounts(:paid_jar).users.create!(name: "Inactive User", active: false)
    system = accounts(:paid_jar).users.create!(name: "System", role: :system)

    assert_equal [ users(:arjun) ], User.where(id: [ users(:arjun).id, inactive.id, system.id ]).active.to_a
  end

  test "owner is an admin" do
    user = accounts(:paid_jar).users.create!(name: "Owner User", role: :owner)

    assert_predicate user, :owner?
    assert_predicate user, :admin?
  end

  test "deactivates a user and releases their identity" do
    user = users(:arjun)
    identity = Identity.create!(email_address: "former-user@example.com")
    user.update!(identity: identity, active: true)

    user.deactivate

    assert_not_predicate user, :active?
    assert_nil user.identity
  end
end

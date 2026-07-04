require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "has many users" do
    assert_includes accounts(:paid_jar).users, users(:arjun)
  end

  test "requires a name" do
    account = Account.new

    assert_not account.valid?
    assert_includes account.errors[:name], "can't be blank"
  end
end

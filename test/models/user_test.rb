require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "belongs to an account" do
    assert_equal accounts(:paid_jar), users(:arjun).account
  end

  test "requires a name and email" do
    user = accounts(:paid_jar).users.build

    assert_not user.valid?
    assert_includes user.errors[:name], "can't be blank"
    assert_includes user.errors[:email], "can't be blank"
  end

  test "normalizes email" do
    user = accounts(:paid_jar).users.create!(name: "New User", email: " New@Example.COM ")

    assert_equal "new@example.com", user.email
  end

  test "filters active users" do
    inactive = accounts(:paid_jar).users.create!(name: "Inactive User", email: "inactive@example.com", active: false)

    assert_equal [ users(:arjun) ], User.where(id: [ users(:arjun).id, inactive.id ]).active.to_a
  end

  test "orders by name" do
    zed = accounts(:paid_jar).users.create!(name: "zed User", email: "zed@example.com")
    alpha = accounts(:paid_jar).users.create!(name: "Alpha User", email: "alpha@example.com")

    assert_equal [ "Alpha User", "zed User" ], User.where(id: [ alpha.id, zed.id ]).ordered.pluck(:name)
  end

  test "filters by name" do
    assert_equal [ users(:arjun) ], User.filtered_by("Arjun").to_a
  end

  test "returns initials" do
    assert_equal "AR", users(:arjun).initials
  end

  test "returns title" do
    assert_equal "Arjun Rajkumar - arjun@example.com", users(:arjun).title
  end
end

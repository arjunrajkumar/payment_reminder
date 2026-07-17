require "test_helper"

class NotificationSubscriptionTest < ActiveSupport::TestCase
  setup do
    @user = users(:arjun)
  end

  test "belongs to a user" do
    subscription = NotificationSubscription.new(
      user: @user,
      event: :invoice_reminder
    )

    assert_equal @user, subscription.user
  end

  test "defines the supported notification events" do
    assert_equal({
      "invoice_reminder" => "invoice_reminder",
      "invoice_reminder_stopped" => "invoice_reminder_stopped"
    }, NotificationSubscription::EVENTS)

    subscription = NotificationSubscription.new(event: :invoice_reminder)

    assert_predicate subscription, :event_invoice_reminder?
  end

  test "requires a supported event" do
    subscription = NotificationSubscription.new(
      user: @user,
      event: "unknown_event"
    )

    assert_not subscription.valid?
    assert_includes subscription.errors[:event], "is not included in the list"
  end

  test "defaults email delivery to disabled" do
    subscription = NotificationSubscription.create!(
      user: @user,
      event: :invoice_reminder
    )

    assert_not_predicate subscription, :email?
  end

  test "does not duplicate an event for a user" do
    NotificationSubscription.create!(
      user: @user,
      event: :invoice_reminder
    )
    duplicate = NotificationSubscription.new(
      user: @user,
      event: :invoice_reminder,
      email: true
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:event], "has already been taken"
  end

  test "enforces event uniqueness for a user in the database" do
    NotificationSubscription.create!(
      user: @user,
      event: :invoice_reminder
    )

    assert_raises ActiveRecord::RecordNotUnique do
      NotificationSubscription.new(
        user: @user,
        event: :invoice_reminder
      ).save!(validate: false)
    end
  end

  test "allows the same event for another user" do
    other_user = @user.account.users.create!(name: "Another Subscriber")
    NotificationSubscription.create!(
      user: @user,
      event: :invoice_reminder
    )
    other_subscription = NotificationSubscription.new(
      user: other_user,
      event: :invoice_reminder
    )

    assert_predicate other_subscription, :valid?
  end

  test "filters subscriptions with email delivery enabled" do
    enabled = NotificationSubscription.create!(
      user: @user,
      event: :invoice_reminder,
      email: true
    )
    disabled = NotificationSubscription.create!(
      user: @user,
      event: :invoice_reminder_stopped,
      email: false
    )

    assert_equal [ enabled ], NotificationSubscription.email_enabled.to_a
    assert_not_includes NotificationSubscription.email_enabled, disabled
  end

  test "deleting a user cascades to subscriptions at the database" do
    user = @user.account.users.create!(name: "Deleted Subscriber")
    subscription = NotificationSubscription.create!(
      user:,
      event: :invoice_reminder
    )

    User.where(id: user.id).delete_all

    assert_not NotificationSubscription.exists?(subscription.id)
  end
end

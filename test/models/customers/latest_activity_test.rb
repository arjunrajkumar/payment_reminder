require "test_helper"

class Customers::LatestActivityTest < ActiveSupport::TestCase
  test "uses the stored example when no description is supplied" do
    activity = Customers::LatestActivity.new(kind: :customer_replied)

    assert_equal "Disputes the phase-two amount", activity.description
  end

  test "uses the activity-specific description when supplied" do
    activity = Customers::LatestActivity.new(
      kind: :customer_replied,
      description: "Customer promises to pay Tuesday"
    )

    assert_equal "Customer promises to pay Tuesday", activity.description
  end

  test "stores the supported activity vocabulary and display metadata" do
    badges = Customers::LatestActivity::BADGES

    assert_equal(
      %i[customer_replied we_replied reminder_sent reminder_opened scheduled payment_received failed no_activity],
      badges.keys
    )
    assert_equal "Scheduled", badges.fetch(:scheduled).fetch(:label)
    assert_equal "paid", badges.fetch(:payment_received).fetch(:tone)
    assert_equal "Email bounced for the billing contact", badges.fetch(:failed).fetch(:example_description)
  end

  test "rejects an unsupported activity kind" do
    assert_raises(KeyError) { Customers::LatestActivity.new(kind: :unknown).description }
  end
end

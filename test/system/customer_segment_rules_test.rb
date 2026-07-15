require "application_system_test_case"

class CustomerSegmentRulesTest < ApplicationSystemTestCase
  test "history rules disable contradictory choices without changing values" do
    sign_up_and_complete(email_address: "segment-history-system@example.com")

    assert_enabled_options "account_payer_segment_minimum_payment_history", 1..5
    assert_enabled_options "account_payer_segment_minimum_unreliable_history", 3..12

    select "10 payments", from: "account_payer_segment_minimum_unreliable_history"

    assert_equal "3", find("#account_payer_segment_minimum_payment_history").value
    assert_enabled_options "account_payer_segment_minimum_payment_history", 1..10
  end

  test "on-time rules disable contradictory choices without changing values" do
    sign_up_and_complete(email_address: "segment-timing-system@example.com")

    assert_enabled_options "account_payer_segment_pays_on_time_rate", (55..100).step(5)
    assert_enabled_options "account_payer_segment_unreliable_on_time_rate", (0..75).step(5)

    select "70%", from: "account_payer_segment_unreliable_on_time_rate"

    assert_equal "80", find("#account_payer_segment_pays_on_time_rate").value
    assert_enabled_options "account_payer_segment_pays_on_time_rate", (75..100).step(5)
  end

  private
    def sign_up_and_complete(email_address:)
      visit new_signup_path
      fill_in "signup_email_address", with: email_address
      click_button "Let's go"

      assert_text "Check your email"
      fill_in "code", with: MagicLink.order(:created_at).last.code
      click_button "Continue"

      fill_in "signup_full_name", with: "Segment Rules"
      click_button "Continue"

      click_link "Settings"
    end

    def assert_enabled_options(field_id, expected_values)
      expected_values = expected_values.map(&:to_s)
      enabled_option = "##{field_id} option:not([disabled])"

      assert_selector enabled_option, count: expected_values.size
      expected_values.each do |value|
        assert_selector "#{enabled_option}[value='#{value}']", count: 1
      end
    end
end

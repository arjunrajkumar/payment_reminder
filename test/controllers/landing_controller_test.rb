require "test_helper"

class LandingControllerTest < ActionDispatch::IntegrationTest
  test "root shows the landing page" do
    get root_url

    assert_response :success
    assert_select "h1", "Welcome to PaidJar"
    assert_select "a[href=?]", new_xero_connection_path, "Connect Xero"
  end

  test "home shows the landing page" do
    get home_url

    assert_response :success
    assert_select "h1", "Welcome to PaidJar"
  end
end

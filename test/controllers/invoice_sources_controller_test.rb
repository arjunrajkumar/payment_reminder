require "test_helper"

class InvoiceSourcesControllerTest < ActionDispatch::IntegrationTest
  test "index requires a PaidJar session" do
    get invoice_sources_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "index shows available invoice sources" do
    sign_up_and_complete

    get invoice_sources_url

    assert_response :success
    assert_select "h1", "Invoice sources"
    assert_select "a[href=?]", new_xero_connection_path, "Connect Xero"
    assert_select "a[href=?]", new_stripe_connection_path, "Connect Stripe"
  end

  test "index shows connected sources" do
    account = sign_up_and_complete(email_address: "owner-sources-connected@example.com")
    account.invoice_sources.create!(
      provider: :stripe,
      status: :active,
      external_account_id: "acct_123",
      external_account_name: "PaidJar Stripe"
    )

    get invoice_sources_url

    assert_response :success
    assert_select "p", "Connected to PaidJar Stripe."
    assert_select "a[href=?]", invoices_path, "View invoices"
    assert_select "a[href=?]", new_stripe_connection_path, count: 0
  end

  private
    def sign_up_and_complete(email_address: "owner-sources@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

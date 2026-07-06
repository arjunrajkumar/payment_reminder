require "test_helper"

class InvoicesControllerTest < ActionDispatch::IntegrationTest
  test "index requires a PaidJar session" do
    get invoices_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "index shows synced invoices" do
    account = sign_up_and_complete
    integration = create_xero_integration(account)
    integration.invoices.create!(
      account: account,
      external_id: "invoice-789",
      number: "INV-789",
      contact_name: "Acme Ltd",
      status: "AUTHORISED",
      currency: "USD",
      total: 300,
      amount_due: 125,
      issued_on: Date.new(2026, 7, 1),
      due_on: Date.new(2026, 7, 31)
    )

    get invoices_url

    assert_response :success
    assert_select "h1", "Invoices"
    assert_select "td", "INV-789"
    assert_select "td", "Acme Ltd"
    assert_select "td", "AUTHORISED"
  end

  test "index paginates synced invoices" do
    account = sign_up_and_complete(email_address: "owner-invoices-pages@example.com")
    integration = create_xero_integration(account)

    16.times do |index|
      issued_on = Date.new(2026, 7, 1) + index

      integration.invoices.create!(
        account: account,
        external_id: "invoice-#{index}",
        number: "INV-#{index.to_s.rjust(3, "0")}",
        contact_name: "Customer #{index}",
        status: "AUTHORISED",
        currency: "USD",
        total: 100 + index,
        amount_due: index,
        issued_on: issued_on,
        due_on: issued_on + 30
      )
    end

    get invoices_url

    assert_response :success
    assert_select "tbody tr", 15
    assert_select "a[href=?]", invoices_path(page: 2), "Load more"

    get invoices_url(page: 2)

    assert_response :success
    assert_select "tbody tr", 1
  end

  private
    def create_xero_integration(account)
      account.accounting_integrations.create!(
        provider: :xero,
        status: :active,
        external_account_id: "tenant-123",
        external_account_name: "PaidJar Xero",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 30.minutes.from_now
      )
    end

    def sign_up_and_complete(email_address: "owner-invoices@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

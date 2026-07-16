require "test_helper"

class InvoicesPaginationControllerTest < ActionDispatch::IntegrationTest
  test "index lazily loads additional invoices in order" do
    account = sign_up_and_complete
    source = create_invoice_source(account)

    16.times do |index|
      number = format("%02d", index + 1)
      create_invoice(source, number: number)
    end

    get invoices_url

    assert_response :success
    assert_equal (1..15).map { |number| "INV-#{format('%02d', number)}" }, rendered_invoice_numbers

    next_page_frame = css_select("turbo-frame#invoices-next-page").sole
    assert_includes next_page_frame["src"], ".turbo_stream"
    assert_includes next_page_frame["src"], "page=2"

    get invoices_url(page: 2, format: :turbo_stream)

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action='append'][target='invoice-rows'] template tr", count: 1
    assert_select "turbo-stream[action='append'][target='invoice-rows'] td[data-label='Invoice due'] .app-invoice-card__number", "INV-16"
    assert_select "turbo-stream[action='remove'][target='invoices-next-page']"
  end

  test "an out-of-range page does not show the account-wide empty state" do
    account = sign_up_and_complete
    source = create_invoice_source(account)
    create_invoice(source, number: "01")

    get invoices_url(page: 99)

    assert_response :success
    assert_select "[data-testid='no-synced-invoices']", count: 0
    assert_select "#invoice-index", count: 1
    assert_empty rendered_invoice_numbers
  end

  private
    def rendered_invoice_numbers
      css_select("#invoice-index tbody td[data-label='Invoice due'] .app-invoice-card__number").map { |number| number.text.squish }
    end

    def create_invoice_source(account)
      account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "xero-pagination-account-#{account.id}",
        external_account_name: "PaymentReminder Xero",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 30.minutes.from_now
      )
    end

    def create_invoice(source, number:)
      company = "Company #{number}"
      customer = source.customers.create!(
        account: source.account,
        external_id: company.parameterize,
        name: company
      )

      source.invoices.create!(
        account: source.account,
        customer: customer,
        external_id: "invoice-#{number}",
        number: "INV-#{number}",
        invoice_type: "ACCREC",
        provider_status: "open",
        status: "open",
        currency: "USD",
        total: 100,
        amount_due: 100,
        amount_paid: 0,
        issued_on: Date.new(2026, 7, 1),
        due_on: 1.week.from_now.to_date
      )
    end

    def sign_up_and_complete
      email_address = "invoice-pagination@example.com"
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

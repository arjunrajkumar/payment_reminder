require "test_helper"

class ReceivablesPaginationControllerTest < ActionDispatch::IntegrationTest
  test "index lazily loads additional receivables in order" do
    account = sign_up_and_complete
    source = create_invoice_source(account)

    16.times do |index|
      number = format("%02d", index + 1)
      create_invoice(
        source,
        external_id: "outstanding-#{number}",
        customer: "Customer #{number}",
        due_on: 1.week.from_now.to_date
      )
    end
    refresh_receivables(source)

    get home_url

    assert_response :success
    assert_equal (1..15).map { |number| format("Customer %02d", number) }, rendered_customer_names

    next_page_frame = css_select("turbo-frame#receivables-next-page").sole
    assert_includes next_page_frame["src"], ".turbo_stream"
    assert_includes next_page_frame["src"], "page=2"
    assert_not_includes next_page_frame["src"], "status="

    get home_url(page: 2, format: :turbo_stream)

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action='append'][target='receivable-rows'] template tr", count: 1
    assert_select "turbo-stream[action='append'][target='receivable-rows'] .app-customer-card__name", "Customer 16"
    assert_select "turbo-stream[action='remove'][target='receivables-next-page']"
  end

  private
    def rendered_customer_names
      css_select("#customer-inbox tbody .app-customer-card__name").map { |name| name.text.squish }
    end

    def refresh_receivables(source)
      source.customers.find_each { |customer| Receivable.refresh_for!(customer) }
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

    def create_invoice(source, external_id:, customer:, due_on:)
      customer_record = source.customers.create!(
        account: source.account,
        external_id: customer.parameterize,
        name: customer
      )

      source.invoices.create!(
        account: source.account,
        customer: customer_record,
        external_id: external_id,
        number: "PAGINATION-#{external_id.upcase}",
        invoice_type: "ACCREC",
        contact_name: customer,
        status: "open",
        currency: "INR",
        total: 100,
        amount_due: 100,
        amount_paid: 0,
        issued_on: Date.new(2026, 7, 1),
        due_on: due_on
      )
    end

    def sign_up_and_complete
      post signup_url, params: { signup: { email_address: "owner-receivable-pagination@example.com" } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

      Identity.find_by!(email_address: "owner-receivable-pagination@example.com").accounts.first
    end
end

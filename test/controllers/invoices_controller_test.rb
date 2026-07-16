require "test_helper"

class InvoicesControllerTest < ActionDispatch::IntegrationTest
  test "index requires a PaymentReminder session" do
    get invoices_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "index shows each invoice with problematic invoices first" do
    account = sign_up_and_complete
    source = create_invoice_source(account)

    travel_to Time.zone.local(2026, 7, 15, 12) do
      create_invoice(source, external_id: "paid", number: "INV-008", company: "Acme Paid", status: "paid", amount_due: 0, due_on: Date.new(2026, 6, 1))
      create_invoice(source, external_id: "current-beta", number: "INV-005", company: "Beta Current", status: "open", amount_due: 100, due_on: Date.new(2026, 7, 20))
      create_invoice(source, external_id: "pending", number: "INV-006", company: "Acme Pending", status: "pending", amount_due: 100, due_on: Date.new(2026, 7, 25))
      overdue_invoice = create_invoice(source, external_id: "overdue", number: "INV-001", company: "Zeta Overdue", status: "open", amount_due: 7_250, due_on: Date.new(2026, 7, 11))
      overdue_invoice.customer.update!(customer_segment: account.customer_segment(:bad_debtor))
      create_invoice(source, external_id: "void", number: "INV-009", company: "Acme Void", status: "void", amount_due: 0, due_on: Date.new(2026, 5, 1))
      create_invoice(source, external_id: "uncollectible", number: "INV-002", company: "Zeta Uncollectible", status: "uncollectible", amount_due: 100, due_on: Date.new(2026, 6, 15))
      create_invoice(source, external_id: "current-alpha", number: "INV-004", company: "Alpha Current", status: "open", amount_due: 100, due_on: Date.new(2026, 7, 20))
      create_invoice(source, external_id: "unknown", number: "INV-003", company: "Zeta Unknown", status: "unknown", amount_due: 100, due_on: Date.new(2026, 7, 15))
      create_invoice(source, external_id: "no-number", number: nil, company: "No Number", status: "pending", amount_due: 20, due_on: nil)

      get invoices_url
    end

    assert_response :success
    assert_select "h1", "Invoices"
    assert_select ".app-period-label", "As of Jul 15, 2026"
    assert_select "#nav a[aria-current='page']", "Invoices"
    assert_select "#invoice-index .app-card.app-table-card", count: 1
    assert_equal(
      [ "Company", "Invoice due", "Status" ],
      css_select("#invoice-index thead th").map { |heading| heading.text.squish }
    )

    rows = css_select("#invoice-index tbody tr")
    assert_equal 9, rows.size
    assert rows.all? { |row| row.css("td").size == 3 }
    assert_equal(
      [ "INV-001", "INV-002", "INV-003", "INV-004", "INV-005", "INV-006", "no-number", "INV-008", "INV-009" ],
      rows.map { |row| row.at_css(".app-invoice-card__number").text.squish }
    )

    overdue_row = rows.first
    company_cell = overdue_row.at_css("td[data-label='Company']")
    assert_includes company_cell["class"].split, "app-customer-card__identity"
    assert_equal "Zeta Overdue", company_cell.at_css(".app-customer-card__name").text.squish
    assert_equal "Bad debtor", company_cell.at_css(".app-customer-card__payer-segment").text.squish
    assert_select overdue_row, "td[data-label='Invoice due'] time", count: 0
    assert_select overdue_row, "td[data-label='Invoice due'] .app-invoice-card__amount", "USD 7,250"
    assert_select overdue_row, "td[data-label='Invoice due'] .app-table-note.app-invoice-card__summary:last-child", "INV-001 4 days overdue"
    assert_select overdue_row, "td[data-label='Status'] .app-invoice-status.app-invoice-status--overdue", "Overdue"

    current_row = rows.find { |row| row.text.include?("INV-004") }
    assert_select current_row, "td[data-label='Invoice due'] .app-invoice-card__summary", "INV-004 due in 5 days"
    assert_select current_row, "td[data-label='Status'] .app-invoice-status.app-invoice-status--outstanding", "Outstanding"

    paid_row = rows.find { |row| row.text.include?("INV-008") }
    assert_select paid_row, "td[data-label='Invoice due'] .app-invoice-card__amount", "USD 0"
    assert_select paid_row, "td[data-label='Status'] .app-invoice-status.app-invoice-status--paid", "Paid"
    assert_select paid_row, "td[data-label='Invoice due'] .app-invoice-card__summary", "INV-008"
    assert_not_includes paid_row.text, "overdue"
  end

  test "index prompts the account to connect an invoice source" do
    account = sign_up_and_complete(email_address: "invoice-empty@example.com")

    get invoices_url

    assert_response :success
    assert_select "[data-testid='no-invoice-source']"
    assert_select "a[href=?]", account_settings_path(script_name: account.slug), "Connect invoice source"
  end

  test "index shows an empty state when no invoices have synced" do
    account = sign_up_and_complete(email_address: "invoice-unsynced@example.com")
    create_invoice_source(account)

    get invoices_url

    assert_response :success
    assert_select "[data-testid='no-synced-invoices']"
  end

  private
    def create_invoice_source(account)
      account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "xero-account-#{account.id}",
        external_account_name: "PaymentReminder Xero",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 30.minutes.from_now
      )
    end

    def create_invoice(source, external_id:, number:, company:, status:, amount_due:, due_on:)
      customer = source.customers.find_or_create_by!(account: source.account, external_id: company.parameterize) do |record|
        record.name = company
      end

      source.invoices.create!(
        account: source.account,
        customer: customer,
        external_id: external_id,
        number: number,
        invoice_type: "ACCREC",
        provider_status: status,
        status: status,
        currency: "USD",
        amount_due: amount_due,
        amount_paid: 0,
        total: amount_due,
        issued_on: Date.new(2026, 7, 1),
        due_on: due_on
      )
    end

    def sign_up_and_complete(email_address: "invoice-owner@example.com")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

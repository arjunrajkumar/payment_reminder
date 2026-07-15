require "test_helper"

class ReceivablesControllerTest < ActionDispatch::IntegrationTest
  test "index requires a PaymentReminder session" do
    get home_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "index orders receivables by invoice status and then customer name" do
    account = sign_up_and_complete
    source = create_invoice_source(account, provider: :xero)

    travel_to Time.zone.local(2026, 7, 11, 12) do
      create_invoice(source, external_id: "current-1", number: "INV-0001", customer: "Nat Dogre", amount_due: 500, due_on: Date.new(2026, 7, 18))
      create_invoice(source, external_id: "current-2", number: "INV-0003", customer: "PixelCraft Labs", amount_due: 12_500, due_on: Date.new(2026, 7, 25))
      create_invoice(source, external_id: "overdue-1", number: "INV-0002", customer: "Nat Dogre", amount_due: 50_000, due_on: Date.new(2026, 7, 7))
      create_invoice(source, external_id: "overdue-2", number: "INV-0007", customer: "Brightside Studio", amount_due: 10_000, amount_paid: 6_000, total: 16_000, due_on: Date.new(2026, 6, 25))
      create_invoice(source, external_id: "overdue-3", number: "INV-0004", customer: "Northstar Consulting", amount_due: 8_400, due_on: Date.new(2026, 6, 1))
      create_invoice(source, external_id: "overdue-4", number: "INV-0005", customer: "Greenline Foods", amount_due: 2_900, due_on: Date.new(2026, 5, 1))
      create_invoice(source, external_id: "overdue-5", number: "INV-0006", customer: "Harbor & Co", amount_due: 950, due_on: Date.new(2026, 3, 31))
      create_invoice(source, external_id: "paid", number: "INV-0008", customer: "Cedar Works", status: "paid", amount_due: 0, amount_paid: 3_200, total: 3_200, due_on: Date.new(2026, 4, 30), paid_on: Date.new(2026, 7, 10))
      create_invoice(source, external_id: "uncollectible", number: "INV-0010", customer: "Zeta Uncollectible", status: "uncollectible", amount_due: 900, due_on: Date.new(2026, 4, 15))
      create_invoice(source, external_id: "draft", number: "INV-0009", customer: "Draft Test Customer", status: "pending", amount_due: 1_100, due_on: Date.new(2026, 7, 31))
      refresh_receivables(source)
      source.customers.find_by!(name: "Nat Dogre").receivable.update!(payer_segment: :slow_payer)

      assert_queries_match(/FROM [`"]invoices[`"]/, count: 1) do
        get home_url
      end
    end

    assert_response :success
    assert_select "h1", "Receivables"
    assert_select "#nav.app-nav[data-controller='toggle-class']"
    assert_select "#nav button[data-action='toggle-class#toggle'][aria-label='Toggle navigation']"
    assert_select "#nav a[aria-current='page']", "Receivables"
    assert_select "#main.app-main"
    assert_select "[data-testid='receivable-status-tabs']", count: 0
    assert_select "table", count: 1
    assert_select "#customer-inbox table thead th", count: 3
    assert_equal(
      [ "Customer", "Receivables", "Status" ],
      css_select("#customer-inbox table thead th").map { |heading| heading.text.squish }
    )

    customer_rows = css_select("#customer-inbox tbody tr")
    customer_names = customer_rows.map { |row| row.at_css(".app-customer-card__name").text.squish }
    assert_equal(
      [ "Brightside Studio", "Greenline Foods", "Harbor & Co", "Nat Dogre", "Northstar Consulting", "PixelCraft Labs", "Cedar Works", "Zeta Uncollectible" ],
      customer_names
    )

    rows_by_name = customer_rows.index_by { |row| row.at_css(".app-customer-card__name").text.squish }
    nat_row = rows_by_name.fetch("Nat Dogre")
    brightside_row = rows_by_name.fetch("Brightside Studio")
    harbor_row = rows_by_name.fetch("Harbor & Co")
    greenline_row = rows_by_name.fetch("Greenline Foods")
    cedar_row = rows_by_name.fetch("Cedar Works")
    pixelcraft_row = rows_by_name.fetch("PixelCraft Labs")

    assert_includes nat_row.text, "Slow payer"
    assert_includes nat_row.text, "INR 50,500"
    assert_includes nat_row.text, "for 2 invoices"
    assert_equal "Overdue", nat_row.at_css("td[data-label='Status']").text.squish

    assert_includes brightside_row.text, "INR 10,000"
    assert_equal "Overdue", brightside_row.at_css("td[data-label='Status']").text.squish

    assert_includes harbor_row.text, "INR 950"
    assert_equal "Overdue", harbor_row.at_css("td[data-label='Status']").text.squish

    assert_includes greenline_row.text, "INR 2,900"
    assert_equal "Overdue", greenline_row.at_css("td[data-label='Status']").text.squish

    assert_includes pixelcraft_row.text, "INR 12,500"
    assert_equal "Outstanding", pixelcraft_row.at_css("td[data-label='Status']").text.squish

    assert_includes cedar_row.text, "Paid in full"
    assert_includes cedar_row.text, "No collection due"
    assert_equal "Paid", cedar_row.at_css("td[data-label='Status']").text.squish

    assert_select "#customer-inbox tbody .app-invoice-status", count: 8

    assert_select "#customer-inbox td[data-label='Customer'] a", count: 0
    assert_select "body", { text: "Draft Test Customer", count: 0 }
    assert_select "form[action=?]", invoice_source_refresh_path(source), count: 0
  end

  test "index shows an empty state when no invoice source is connected" do
    account = sign_up_and_complete(email_address: "owner-receivables-empty@example.com")

    get home_url

    assert_response :success
    assert_select "[data-testid='no-invoice-source']"
    assert_select "a[href=?]", account_settings_path(script_name: account.slug), "Connect invoice source"
  end

  test "index shows a refresh state when a source has no synced invoices" do
    account = sign_up_and_complete(email_address: "owner-receivables-unsynced@example.com")
    source = create_invoice_source(account, provider: :xero)

    get home_url

    assert_response :success
    assert_select "[data-testid='no-synced-invoices']"
    assert_select "a[href=?]", account_settings_path(script_name: account.slug), "Open Settings"
    assert_select "form[action=?]", invoice_source_refresh_path(source), count: 0
  end

  test "index explains when only draft invoices have synced" do
    account = sign_up_and_complete(email_address: "owner-receivables-drafts@example.com")
    source = create_invoice_source(account, provider: :xero)
    create_invoice(source, external_id: "draft-only", number: "DRAFT-1", customer: "Draft Customer", status: "pending", amount_due: 1_100)
    refresh_receivables(source)

    get home_url

    assert_response :success
    assert_select "[data-testid='no-issued-invoices']"
    assert_select "body", { text: "Draft Customer", count: 0 }
  end

  test "index distinguishes uncollectible invoices from open and paid invoices" do
    account = sign_up_and_complete(email_address: "owner-receivables-uncollectible@example.com")
    source = create_invoice_source(account, provider: :stripe)

    create_invoice(source, external_id: "closed-paid", number: "CLOSED-PAID", customer: "Closed Customer", status: "paid", amount_due: 0, amount_paid: 100, total: 100)
    create_invoice(source, external_id: "closed-uncollectible", number: "CLOSED-BAD", customer: "Closed Customer", status: "uncollectible", amount_due: 400)
    create_invoice(source, external_id: "mixed-open", number: "MIXED-OPEN", customer: "Mixed Customer", amount_due: 100)
    create_invoice(source, external_id: "mixed-uncollectible", number: "MIXED-BAD", customer: "Mixed Customer", status: "uncollectible", amount_due: 75)
    create_invoice(source, external_id: "zero-open", number: "ZERO-OPEN", customer: "Zero Balance Customer", amount_due: 0)
    create_invoice(source, external_id: "zero-uncollectible", number: "ZERO-BAD", customer: "Zero Balance Customer", status: "uncollectible", amount_due: 50)
    refresh_receivables(source)

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get home_url
    end

    assert_response :success
    rows = css_select("#customer-inbox tbody tr")
    closed_row = rows.find { |row| row.text.include?("Closed Customer") }
    mixed_row = rows.find { |row| row.text.include?("Mixed Customer") }
    zero_balance_row = rows.find { |row| row.text.include?("Zero Balance Customer") }

    assert_includes closed_row.text, "INR 400 uncollectible"
    assert_includes closed_row.text, "1 invoice marked uncollectible"
    assert_equal "Uncollectible", closed_row.at_css("td[data-label='Status']").text.squish
    assert_not_includes closed_row.text, "Paid in full"

    assert_includes mixed_row.text, "INR 100"
    assert_includes mixed_row.text, "1 invoice marked uncollectible"
    assert_equal "Outstanding", mixed_row.at_css("td[data-label='Status']").text.squish
    assert_not_includes mixed_row.text, "Paid in full"

    assert_includes zero_balance_row.text, "1 open invoice with no balance due"
    assert_includes zero_balance_row.text, "1 invoice marked uncollectible"
    assert_equal "Uncollectible", zero_balance_row.at_css("td[data-label='Status']").text.squish
    assert_not_includes zero_balance_row.text, "Paid in full"
  end

  test "index does not call an open invoice paid when no balance is due" do
    account = sign_up_and_complete(email_address: "owner-receivables-open-zero@example.com")
    source = create_invoice_source(account, provider: :stripe)
    create_invoice(
      source,
      external_id: "open-zero",
      number: "OPEN-ZERO",
      customer: "Open Customer",
      status: "open",
      amount_due: 0,
      total: 100
    )
    refresh_receivables(source)

    get home_url

    assert_response :success
    row = css_select("#customer-inbox tbody tr").sole
    assert_includes row.text, "No balance due"
    assert_equal "Open", row.at_css("td[data-label='Status']").text.squish
    assert_not_includes row.text, "Paid in full"
  end

  private
    def refresh_receivables(source)
      source.customers.find_each { |customer| Receivable.refresh_for!(customer) }
    end

    def create_invoice_source(account, provider:)
      account.invoice_sources.create!(
        provider: provider,
        status: :active,
        external_account_id: "#{provider}-account-#{account.id}",
        external_account_name: "PaymentReminder #{provider.to_s.titleize}",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 30.minutes.from_now
      )
    end

    def create_invoice(source, external_id:, number:, customer:, amount_due:, due_on: 2.weeks.from_now.to_date, status: "open", amount_paid: 0, total: nil, invoice_type: "ACCREC", paid_on: nil)
      customer_record = source.customers.find_or_create_by!(
        account: source.account,
        external_id: customer.parameterize
      ) { |record| record.name = customer }

      source.invoices.create!(
        account: source.account,
        customer: customer_record,
        external_id: external_id,
        number: number,
        invoice_type: invoice_type,
        contact_name: customer,
        status: status,
        currency: "INR",
        total: total || amount_due,
        amount_due: amount_due,
        amount_paid: amount_paid,
        issued_on: Date.new(2026, 7, 11),
        due_on: due_on,
        paid_on: paid_on
      )
    end

    def sign_up_and_complete(email_address: "owner-receivables@example.com")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

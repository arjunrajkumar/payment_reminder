require "test_helper"

class ReceivablesControllerTest < ActionDispatch::IntegrationTest
  test "index requires a PaymentReminder session" do
    get home_url

    assert_redirected_to new_session_url(script_name: nil)
  end

  test "index shows receivables ordered by collection priority" do
    account = sign_up_and_complete
    source = create_invoice_source(account, provider: :xero)
    harbor = nil

    travel_to Time.zone.local(2026, 7, 11, 12) do
      create_invoice(source, external_id: "current-1", number: "INV-0001", customer: "Nat Dogre", amount_due: 500, due_on: Date.new(2026, 7, 18))
      create_invoice(source, external_id: "current-2", number: "INV-0003", customer: "PixelCraft Labs", amount_due: 12_500, due_on: Date.new(2026, 7, 25))
      create_invoice(source, external_id: "overdue-1", number: "INV-0002", customer: "Nat Dogre", amount_due: 50_000, due_on: Date.new(2026, 7, 7))
      create_invoice(source, external_id: "overdue-2", number: "INV-0007", customer: "Brightside Studio", amount_due: 10_000, amount_paid: 6_000, total: 16_000, due_on: Date.new(2026, 6, 25))
      create_invoice(source, external_id: "overdue-3", number: "INV-0004", customer: "Northstar Consulting", amount_due: 8_400, due_on: Date.new(2026, 6, 1))
      create_invoice(source, external_id: "overdue-4", number: "INV-0005", customer: "Greenline Foods", amount_due: 2_900, due_on: Date.new(2026, 5, 1))
      harbor = create_invoice(source, external_id: "overdue-5", number: "INV-0006", customer: "Harbor & Co", amount_due: 950, due_on: Date.new(2026, 3, 31))
      create_invoice(source, external_id: "paid", number: "INV-0008", customer: "Cedar Works", status: "PAID", amount_due: 0, amount_paid: 3_200, total: 3_200, due_on: Date.new(2026, 4, 30), paid_on: Date.new(2026, 7, 10))
      create_invoice(source, external_id: "draft", number: "INV-0009", customer: "Draft Test Customer", status: "DRAFT", amount_due: 1_100, due_on: Date.new(2026, 7, 31))

      get home_url
    end

    assert_response :success
    assert_select "h1", "Receivables"
    assert_select "#nav.app-nav[data-controller='toggle-class']"
    assert_select "#nav button[data-action='toggle-class#toggle'][aria-label='Toggle navigation']"
    assert_select "#nav a[aria-current='page']", "Receivables"
    assert_select "#main.app-main"
    assert_select "table", count: 1
    assert_select "#collection-priorities table thead th", count: 4
    assert_equal(
      [ "Customer", "Receivable", "Payment summary", "Status" ],
      css_select("#collection-priorities table thead th").map { |heading| heading.text.squish }
    )

    customer_rows = css_select("#collection-priorities tbody tr")
    customer_names = customer_rows.map { |row| row.at_css("td[data-label='Customer'] a").text.squish }
    assert_equal(
      [ "Brightside Studio", "Harbor & Co", "Greenline Foods", "Northstar Consulting", "Nat Dogre", "PixelCraft Labs", "Cedar Works" ],
      customer_names
    )

    brightside_row, harbor_row, greenline_row, _, nat_row, _, cedar_row = customer_rows
    assert_equal "waiting", nat_row["data-conversation-state"]
    assert_includes nat_row.text, "New"
    assert_includes nat_row.text, "Customer says payment is being processed"
    assert_includes nat_row.text, "In progress"
    assert_includes nat_row.text, "for 2 invoices"

    assert_equal "dispute", brightside_row["data-conversation-state"]
    assert_includes brightside_row.text, "Sometimes late"
    assert_includes brightside_row.text, "Customer disputes the phase-two amount"
    assert_includes brightside_row.text, "Needs attention"

    assert_equal "no_reply", harbor_row["data-conversation-state"]
    assert_includes harbor_row.text, "Unreliable payer"
    assert_includes harbor_row.text, "Escalate to a person"
    assert_includes harbor_row.text, "Unpaid"

    assert_includes greenline_row.text, "Slow payer"
    assert_includes greenline_row.text, "Waiting for their reply"
    assert_includes greenline_row.text, "In progress"

    assert_includes cedar_row.text, "Paid in full"
    assert_includes cedar_row.text, "No follow-up needed"
    assert_includes cedar_row.text, "Paid"

    assert_select "#collection-priorities tbody .app-pill", count: 0
    assert_select "#collection-priorities tbody .app-collection-status", count: 7

    assert_select "a[href=?]", customer_path(customer_key_for(harbor)), "Harbor & Co"
    assert_select "body", { text: "Draft Test Customer", count: 0 }
    assert_select "form[action=?]", invoice_source_refresh_path(source), count: 0
    assert_select "#aging-breakdown-title", "Breakdown of outstanding receivables"
    assert_select ".app-aging-chart", count: 1
    assert_select "[data-testid^='aging-']", count: 5
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
    create_invoice(source, external_id: "draft-only", number: "DRAFT-1", customer: "Draft Customer", status: "DRAFT", amount_due: 1_100)

    get home_url

    assert_response :success
    assert_select "[data-testid='no-issued-invoices']"
    assert_select "body", { text: "Draft Customer", count: 0 }
  end

  private
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

    def create_invoice(source, external_id:, number:, customer:, amount_due:, due_on: 2.weeks.from_now.to_date, status: "AUTHORISED", amount_paid: 0, total: nil, invoice_type: "ACCREC", paid_on: nil)
      source.invoices.create!(
        account: source.account,
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

    def customer_key_for(invoice)
      Customers::Profile.encode_identity(Customers::Profile.identity_for(invoice))
    end

    def sign_up_and_complete(email_address: "owner-receivables@example.com")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

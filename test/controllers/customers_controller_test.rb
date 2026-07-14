require "test_helper"

class CustomersControllerTest < ActionDispatch::IntegrationTest
  test "index redirects to the canonical customer inbox" do
    account = sign_up_and_complete

    get customers_url(script_name: account.slug)

    assert_redirected_to home_url(script_name: account.slug)
  end

  test "show presents the payment summary and invoice timing from persisted invoices" do
    account = sign_up_and_complete(email_address: "owner-customer-show@example.com")
    source = create_invoice_source(account)
    paid = create_invoice(
      source,
      external_id: "harbor-paid",
      contact_external_id: "harbor",
      customer: "Harbor & Co",
      amount_due: 0,
      amount_paid: 1_200,
      total: 1_200,
      status: "paid",
      issued_on: Date.new(2026, 1, 1),
      due_on: Date.new(2026, 1, 31),
      paid_on: Date.new(2026, 2, 5)
    )
    create_invoice(
      source,
      external_id: "harbor-overdue",
      contact_external_id: "harbor",
      customer: "Harbor & Co",
      amount_due: 950,
      issued_on: Date.new(2026, 3, 1),
      due_on: Date.new(2026, 3, 31)
    )
    create_invoice(source, external_id: "other", contact_external_id: "other", customer: "Other Customer", amount_due: 500)

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get customer_url(paid.customer, script_name: account.slug)
    end

    assert_response :success
    assert_select "h1", "Harbor & Co"
    assert_select ".app-page-subtitle", "Customer segment: New"
    assert_select ".app-customer-header .app-invoice-status", "Overdue"
    assert_select "#payment-summary-title", "Payment summary"
    assert_select ".app-customer-summary__copy", count: 0
    assert_select ".app-customer-summary__receivable", text: /INR 950 outstanding/
    assert_select ".app-customer-summary__receivable", text: /1 invoice/
    assert_select "#payment-pattern-title", "Invoice timing"
    assert_select "[data-testid='payment-history-event']", 2
    assert_select "[data-testid='payment-history-event']", text: /HARBOR-PAID.*5 days late/m
    assert_select "[data-testid='payment-history-event']", text: /HARBOR-OVERDUE.*102 days overdue/m
    assert_select "#conversation", count: 0
    assert_select "body", { text: /reminder|reply|escalate/i, count: 0 }
    assert_select "#open-invoices, #customer-invoices, [data-testid='customer-recommendation']", count: 0
    assert_select "body", { text: "Other Customer", count: 0 }
  end

  test "show plots every dated invoice on the invoice timing graph" do
    account = sign_up_and_complete(email_address: "owner-customer-anomaly@example.com")
    source = create_invoice_source(account)
    unusual = create_invoice(source, external_id: "unusual", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 0, amount_paid: 100, total: 100, status: "paid", issued_on: Date.new(2026, 1, 1), due_on: Date.new(2026, 7, 31), paid_on: Date.new(2026, 1, 29))
    create_invoice(source, external_id: "typical-1", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 0, amount_paid: 100, total: 100, status: "paid", issued_on: Date.new(2026, 2, 1), due_on: Date.new(2026, 2, 28), paid_on: Date.new(2026, 2, 28))
    create_invoice(source, external_id: "typical-2", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 0, amount_paid: 100, total: 100, status: "paid", issued_on: Date.new(2026, 3, 1), due_on: Date.new(2026, 3, 31), paid_on: Date.new(2026, 3, 28))
    create_invoice(source, external_id: "current", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 250, due_on: Date.new(2026, 7, 25))

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get customer_url(unusual.customer, script_name: account.slug)
    end

    assert_response :success
    assert_select ".app-page-subtitle", "Customer segment: Pays on time"
    assert_select ".app-customer-header .app-invoice-status", "Outstanding"
    assert_select "[data-testid='payment-history-event']", 4
    assert_select "[data-testid='payment-history-event']", text: /UNUSUAL.*183 days early/m
    assert_select "[data-testid='payment-history-event']", text: /TYPICAL-1.*On due date/m
    assert_select "[data-testid='payment-history-event']", text: /TYPICAL-2.*3 days early/m
    assert_select "[data-testid='payment-history-event']", text: /CURRENT.*Due in 14 days/m
  end

  test "show qualifies each outstanding currency without prototype communication content" do
    account = sign_up_and_complete(email_address: "owner-generic-customer@example.com")
    source = create_invoice_source(account)
    customer_invoice = create_invoice(
      source,
      external_id: "generic-inr",
      contact_external_id: "generic",
      customer: "Generic Customer",
      amount_due: 100
    )
    create_invoice(
      source,
      external_id: "generic-usd",
      contact_external_id: "generic",
      customer: "Generic Customer",
      amount_due: 200,
      currency: "USD"
    )

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get customer_url(customer_invoice.customer, script_name: account.slug)
    end

    assert_response :success
    assert_select ".app-customer-summary__receivable .app-currency-total", 2
    assert_select ".app-customer-summary__receivable .app-currency-total", "INR 100 outstanding"
    assert_select ".app-customer-summary__receivable .app-currency-total", "USD 200 outstanding"
    assert_select ".app-customer-summary__copy", count: 0
    assert_select "#conversation", count: 0
    assert_select "body", { text: /message|reminder|reply/i, count: 0 }
  end

  test "show identifies a paid invoice when the provider omits its payment date" do
    account = sign_up_and_complete(email_address: "owner-customer-paid-without-date@example.com")
    source = create_invoice_source(account)
    paid = create_invoice(
      source,
      external_id: "paid-without-date",
      contact_external_id: "paid-without-date",
      customer: "Paid Customer",
      amount_due: 0,
      amount_paid: 100,
      total: 100,
      status: "paid",
      due_on: Date.new(2026, 6, 30)
    )

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get customer_url(paid.customer, script_name: account.slug)
    end

    assert_response :success
    assert_select "[data-testid='payment-history-event']", text: /PAID-WITHOUT-DATE.*Paid.*Date unavailable/m
    assert_select "[data-testid='payment-history-event'] .app-payment-event__marker", count: 0
  end

  test "show does not present an open invoice with no balance as paid or overdue" do
    account = sign_up_and_complete(email_address: "owner-customer-open-zero@example.com")
    source = create_invoice_source(account, provider: :stripe)
    invoice = create_invoice(
      source,
      external_id: "open-zero",
      contact_external_id: "open-zero-customer",
      customer: "Open Customer",
      amount_due: 0,
      total: 100,
      status: "open",
      due_on: Date.new(2026, 6, 30)
    )

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get customer_url(invoice.customer, script_name: account.slug)
    end

    assert_response :success
    assert_select ".app-customer-header .app-invoice-status", "Open"
    assert_select ".app-customer-summary__copy", count: 0
    assert_select ".app-customer-summary__receivable", text: /No balance due.*1 open invoice/m
    assert_select "body", { text: "Paid in full", count: 0 }
    assert_select "body", { text: /collection follow-up|reminder|reply/i, count: 0 }
    assert_select "[data-testid='payment-history-event']", text: /OPEN-ZERO.*Open.*no balance due.*No balance due/m
    assert_select "[data-testid='payment-history-event'] .app-payment-event__marker", count: 0
  end

  test "show presents an uncollectible invoice as terminal rather than paid or overdue" do
    account = sign_up_and_complete(email_address: "owner-customer-uncollectible@example.com")
    source = create_invoice_source(account, provider: :stripe)
    paid = create_invoice(
      source,
      external_id: "closed-paid",
      contact_external_id: "closed-customer",
      customer: "Closed Customer",
      amount_due: 0,
      amount_paid: 100,
      total: 100,
      status: "paid",
      due_on: Date.new(2026, 5, 31),
      paid_on: Date.new(2026, 5, 30)
    )
    create_invoice(
      source,
      external_id: "closed-uncollectible",
      contact_external_id: "closed-customer",
      customer: "Closed Customer",
      amount_due: 300,
      status: "uncollectible",
      due_on: Date.new(2026, 6, 1)
    )

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get customer_url(paid.customer, script_name: account.slug)
    end

    assert_response :success
    assert_select ".app-customer-header .app-invoice-status", "Uncollectible"
    assert_select ".app-customer-summary__copy", count: 0
    assert_select ".app-customer-summary__receivable", text: /INR 300 uncollectible/
    assert_select ".app-customer-summary__receivable", text: /1 uncollectible invoice/
    assert_select "body", { text: "Paid in full", count: 0 }
    assert_select "[data-testid='payment-history-event']", text: /CLOSED-UNCOLLECTIBLE.*Uncollectible/m
    uncollectible_event = css_select("[data-testid='payment-history-event']").find { |event| event.text.include?("CLOSED-UNCOLLECTIBLE") }
    assert_nil uncollectible_event.at_css(".app-payment-event__marker")
    assert_select "#conversation", count: 0
    assert_select "body", { text: /collection follow-up|reminder|reply/i, count: 0 }
  end

  test "show does not expose another account customer" do
    account = sign_up_and_complete(email_address: "owner-customer-scope@example.com")
    other_account = Account.create_with_owner(
      account: { name: "Other Account" },
      owner: { identity: Identity.create!(email_address: "other-customer@example.com"), name: "Other Owner" }
    )
    other_source = create_invoice_source(other_account)
    other_invoice = create_invoice(other_source, external_id: "private", contact_external_id: "private", customer: "Private Customer", amount_due: 500)

    get customer_url(other_invoice.customer, script_name: account.slug)

    assert_response :not_found
  end

  private
    def create_invoice_source(account, provider: :xero)
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

    def create_invoice(source, external_id:, contact_external_id:, customer:, amount_due:, issued_on: Date.new(2026, 7, 1), due_on: Date.new(2026, 7, 31), paid_on: nil, status: "open", amount_paid: 0, total: nil, currency: "INR")
      customer_record = source.customers.find_or_create_by!(
        account: source.account,
        external_id: contact_external_id
      ) { |record| record.name = customer }

      source.invoices.create!(
        account: source.account,
        customer: customer_record,
        external_id: external_id,
        number: external_id.upcase,
        invoice_type: "ACCREC",
        contact_external_id: contact_external_id,
        contact_name: customer,
        status: status,
        currency: currency,
        total: total || amount_due,
        amount_due: amount_due,
        amount_paid: amount_paid,
        issued_on: issued_on,
        due_on: due_on,
        paid_on: paid_on
      )
    end

    def sign_up_and_complete(email_address: "owner-customers@example.com")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

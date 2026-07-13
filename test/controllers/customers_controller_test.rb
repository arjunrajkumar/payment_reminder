require "test_helper"

class CustomersControllerTest < ActionDispatch::IntegrationTest
  test "index redirects to the canonical customer inbox" do
    account = sign_up_and_complete

    get customers_url(script_name: account.slug)

    assert_redirected_to home_url(script_name: account.slug)
  end

  test "show presents the payment summary invoice timing and conversation" do
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
      status: "PAID",
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
      get customer_url(customer_key_for(paid), script_name: account.slug)
    end

    assert_response :success
    assert_select "h1", "Harbor & Co"
    assert_select ".app-page-subtitle", "Customer segment: Unreliable payer"
    assert_select ".app-customer-header .app-collection-status", "Unpaid"
    assert_select "#payment-summary-title", "Payment summary"
    assert_select ".app-customer-summary__copy", text: /No reply after three reminders/
    assert_select ".app-customer-summary__receivable", text: /INR 950 outstanding/
    assert_select ".app-customer-summary__receivable", text: /1 invoice/
    assert_select "#payment-pattern-title", "Invoice timing"
    assert_select "[data-testid='payment-history-event']", 2
    assert_select "[data-testid='payment-history-event']", text: /HARBOR-PAID.*5 days late/m
    assert_select "[data-testid='payment-history-event']", text: /HARBOR-OVERDUE.*102 days overdue/m
    assert_select "#conversation", text: /Conversation/
    assert_select "#conversation", text: /No response after three reminders/
    assert_select "#open-invoices, #customer-invoices, [data-testid='customer-recommendation']", count: 0
    assert_select "body", { text: "Other Customer", count: 0 }
  end

  test "show plots every dated invoice on the invoice timing graph" do
    account = sign_up_and_complete(email_address: "owner-customer-anomaly@example.com")
    source = create_invoice_source(account)
    unusual = create_invoice(source, external_id: "unusual", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 0, amount_paid: 100, total: 100, status: "PAID", issued_on: Date.new(2026, 1, 1), due_on: Date.new(2026, 7, 31), paid_on: Date.new(2026, 1, 29))
    create_invoice(source, external_id: "typical-1", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 0, amount_paid: 100, total: 100, status: "PAID", issued_on: Date.new(2026, 2, 1), due_on: Date.new(2026, 2, 28), paid_on: Date.new(2026, 2, 28))
    create_invoice(source, external_id: "typical-2", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 0, amount_paid: 100, total: 100, status: "PAID", issued_on: Date.new(2026, 3, 1), due_on: Date.new(2026, 3, 31), paid_on: Date.new(2026, 3, 28))
    create_invoice(source, external_id: "current", contact_external_id: "reliable", customer: "Reliable Customer", amount_due: 250, due_on: Date.new(2026, 7, 25))

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get customer_url(customer_key_for(unusual), script_name: account.slug)
    end

    assert_response :success
    assert_select ".app-page-subtitle", "Customer segment: Pays on time"
    assert_select ".app-customer-header .app-collection-status", "In progress"
    assert_select "[data-testid='payment-history-event']", 4
    assert_select "[data-testid='payment-history-event']", text: /UNUSUAL.*183 days early/m
    assert_select "[data-testid='payment-history-event']", text: /TYPICAL-1.*On due date/m
    assert_select "[data-testid='payment-history-event']", text: /TYPICAL-2.*3 days early/m
    assert_select "[data-testid='payment-history-event']", text: /CURRENT.*Due in 14 days/m
  end

  test "show keeps an uncontacted customer's conversation empty and qualifies each outstanding currency" do
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
      get customer_url(customer_key_for(customer_invoice), script_name: account.slug)
    end

    assert_response :success
    assert_select ".app-customer-summary__receivable .app-currency-total", 2
    assert_select ".app-customer-summary__receivable .app-currency-total", "INR 100 outstanding"
    assert_select ".app-customer-summary__receivable .app-currency-total", "USD 200 outstanding"
    assert_select "#conversation .app-empty-inline", "No message or payment activity yet"
    assert_select "#conversation .app-conversation-event", count: 0
    assert_select "#conversation", { text: /Invoice shared|was emailed|Jul 3/, count: 0 }
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
      status: "PAID",
      due_on: Date.new(2026, 6, 30)
    )

    travel_to Time.zone.local(2026, 7, 11, 12) do
      get customer_url(customer_key_for(paid), script_name: account.slug)
    end

    assert_response :success
    assert_select "[data-testid='payment-history-event']", text: /PAID-WITHOUT-DATE.*Paid.*Date unavailable/m
    assert_select "[data-testid='payment-history-event'] .app-payment-event__marker", count: 0
  end

  test "show does not expose another account customer" do
    account = sign_up_and_complete(email_address: "owner-customer-scope@example.com")
    other_account = Account.create_with_owner(
      account: { name: "Other Account" },
      owner: { identity: Identity.create!(email_address: "other-customer@example.com"), name: "Other Owner" }
    )
    other_source = create_invoice_source(other_account)
    other_invoice = create_invoice(other_source, external_id: "private", contact_external_id: "private", customer: "Private Customer", amount_due: 500)

    get customer_url(customer_key_for(other_invoice), script_name: account.slug)

    assert_response :not_found
  end

  private
    def create_invoice_source(account)
      account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "tenant-#{account.id}",
        external_account_name: "PaymentReminder Xero",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 30.minutes.from_now
      )
    end

    def create_invoice(source, external_id:, contact_external_id:, customer:, amount_due:, issued_on: Date.new(2026, 7, 1), due_on: Date.new(2026, 7, 31), paid_on: nil, status: "AUTHORISED", amount_paid: 0, total: nil, currency: "INR")
      source.invoices.create!(
        account: source.account,
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

    def customer_key_for(invoice)
      Customers::Profile.encode_identity(Customers::Profile.identity_for(invoice))
    end

    def sign_up_and_complete(email_address: "owner-customers@example.com")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: "Owner Person" } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

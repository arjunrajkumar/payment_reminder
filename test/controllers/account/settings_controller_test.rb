require "test_helper"

class Account::SettingsControllerTest < ActionDispatch::IntegrationTest
  test "show renders simplified account settings" do
    account = sign_up_and_complete

    get account_settings_url(script_name: account.slug)

    assert_response :success
    assert_select "h1", "Settings"
    assert_select "#nav a[aria-current='page']", "Settings"
    assert_select ".app-card__title", "Business profile"
    assert_select ".app-field", account.name
    assert_select ".app-field", count: 1
    assert_select "body", { text: "owner-settings@example.com", count: 0 }
    assert_select "body", { text: "Billing email", count: 0 }
    assert_select "body", { text: "Currency", count: 0 }
    assert_select ".app-card__title", "Accounting integration"
    assert_select "a[href=?]", new_xero_connection_path, "Connect"
    assert_select "a[href=?]", new_stripe_connection_path, "Connect"
    assert_select ".app-card", count: 4
    assert_select ".app-card", text: /Invoice reminders/ do
      assert_select "a[href=?]", new_gmail_connection_path(script_name: account.slug), "Connect Gmail"
      assert_select "input[name='account[invoice_reminder_from_email]']", count: 0
      assert_select "input[name='account[automatic_invoice_reminders_enabled]'][type='checkbox'][disabled]:not([checked])"
      assert_select "input[type='submit'][value='Save reminder settings']"
    end
    assert_select "section", { text: "Reminder cadence", count: 0 }
    assert_select ".app-card", text: /Notifications/ do
      assert_select "form[action=?]", account_notification_preferences_path(script_name: account.slug) do
        assert_select "input[name='notifications[invoice_reminder]'][type='checkbox']:not([checked])"
        assert_select "input[name='notifications[invoice_reminder_stopped]'][type='checkbox']:not([checked])"
        assert_select "input[type='submit'][value='Save notification preferences']"
      end
    end
    assert_select "form[action=?]", session_path(script_name: nil) do
      assert_select "button", "Sign out"
    end
  end

  test "connected invoice sources can be resynced" do
    account = sign_up_and_complete(email_address: "owner-settings-resync@example.com")
    source = account.invoice_sources.create!(
      provider: :xero,
      status: :active,
      external_account_id: "tenant-settings-resync",
      external_account_name: "PaymentReminder Xero",
      access_token: "access-token",
      refresh_token: "refresh-token",
      expires_at: 30.minutes.from_now
    )

    get account_settings_url(script_name: account.slug)

    assert_response :success
    assert_select ".app-pill", "Connected"
    assert_select "form[action=?]", invoice_source_refresh_path(source) do
      assert_select "button", "Resync"
    end
  end

  test "connected Gmail shows its address status sender controls and delivery actions" do
    account = sign_up_and_complete(email_address: "owner-connected-gmail@example.com")
    connect_gmail(account, email: "billing@example.com")

    get account_settings_url(script_name: account.slug)

    assert_response :success
    assert_select ".app-card", text: /Invoice reminders/ do
      assert_select ".app-row__note", "billing@example.com"
      assert_select ".app-pill", "Active"
      assert_select "input[name='account[invoice_reminder_from_name]'][value=?]", account.name
      assert_select "input[name='account[invoice_reminder_from_email]']", count: 0
      assert_select "a[href=?]", new_gmail_connection_path(script_name: account.slug), "Reconnect Gmail"
      assert_select "form[action=?]", test_gmail_connection_path(script_name: account.slug)
      assert_select "form[action=?]", gmail_connection_path(script_name: account.slug)
      assert_select "input[name='account[automatic_invoice_reminders_enabled]'][type='checkbox']:not([disabled])"
    end
  end

  test "show renders debtor rating rules" do
    account = sign_up_and_complete(email_address: "owner-segment-settings@example.com")

    get account_settings_url(script_name: account.slug)

    assert_response :success
    assert_select ".app-segment-rules-card" do
      assert_select ".app-card__title", "Debtor ratings"
      assert_select ".app-segment-rules-card__description", text: /12 most recent completed payment outcomes/
      assert_select ".app-segment-rules-card__description", text: /Draft, open, and overdue invoices are excluded until resolved/
      assert_select ".app-segment-rules-card__description", text: /fewer than 3 completed outcomes are always Normal Debtors/
      assert_select "th", "Segment"
      assert_select "th", "Current rule"
      assert_select "th", "Adjust rule"
      assert_select "tbody tr", count: 3
      assert_select "select", count: 2
      assert_select "form[action=?]", account_settings_path(script_name: account.slug)
      assert_select "form[action=?]", account_customer_segment_refresh_path(script_name: account.slug) do
        assert_select "button", "Refresh ratings"
      end
    end
  end

  test "update saves debtor rating rules for the current account" do
    account = sign_up_and_complete(email_address: "owner-segment-update@example.com")
    other_account = Account.create!(name: "Other Segment Account")

    patch account_settings_url(script_name: account.slug), params: {
      account: { customer_segments_attributes: debtor_rating_attributes(account) }
    }

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Debtor rating rules saved. Refresh ratings to apply them.", flash[:notice]
    assert_equal 85, account.customer_segment(:good_debtor).reload.on_time_rate
    assert_equal 45, account.customer_segment(:bad_debtor).reload.on_time_rate
    assert_equal 80, other_account.customer_segment(:good_debtor).on_time_rate
    assert_equal 50, other_account.customer_segment(:bad_debtor).on_time_rate
  end

  test "update enables automatic invoice reminders for the current account" do
    account = sign_up_and_complete(email_address: "owner-reminder-settings@example.com")
    connect_gmail(account, email: "billing@example.com")
    other_account = Account.create!(name: "Other Reminder Settings Account")

    patch account_settings_url(script_name: account.slug), params: {
      account: { automatic_invoice_reminders_enabled: "1" }
    }

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Invoice reminder settings saved.", flash[:notice]
    assert_predicate account.reload, :automatic_invoice_reminders_enabled?
    assert_not_predicate other_account.reload, :automatic_invoice_reminders_enabled?
  end

  test "update saves the invoice reminder sender name for the current account" do
    account = sign_up_and_complete(email_address: "owner-sender-settings@example.com")
    connect_gmail(account, email: "billing@example.com")
    other_account = Account.create!(name: "Other Sender Settings Account")

    patch account_settings_url(script_name: account.slug), params: {
      account: { invoice_reminder_from_name: "Accounts Team" }
    }

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Invoice reminder settings saved.", flash[:notice]
    assert_equal "Accounts Team", account.reload.invoice_reminder_from_name
    assert_nil other_account.reload.invoice_reminder_from_name
  end

  test "update refuses to enable reminders without an active Gmail connection" do
    account = sign_up_and_complete(email_address: "owner-invalid-sender@example.com")

    patch account_settings_url(script_name: account.slug), params: {
      account: {
        automatic_invoice_reminders_enabled: "1"
      }
    }

    assert_response :unprocessable_entity
    assert_select "#flash", text: /requires an active Gmail connection/
    assert_not_predicate account.reload, :automatic_invoice_reminders_enabled?
    assert_nil account.invoice_reminder_from_email
  end

  test "update saves notification preferences for the current user" do
    account = sign_up_and_complete(email_address: "owner-notifications@example.com")
    current_user = Identity.find_by!(email_address: "owner-notifications@example.com").users.find_by!(account:)
    other_user = Account.create_with_owner(
      account: { name: "Other Notifications Account" },
      owner: {
        name: "Other Owner",
        identity: Identity.create!(email_address: "other-notifications@example.com")
      }
    ).users.owner.first
    other_user.notification_subscriptions.create!(event: :invoice_reminder, email: true)
    other_membership = other_user.account.users.create!(
      name: "Owner in another account",
      identity: current_user.identity
    )
    other_membership.notification_subscriptions.create!(event: :invoice_reminder, email: false)

    patch account_notification_preferences_url(script_name: account.slug), params: {
      notifications: {
        invoice_reminder: "1"
      }
    }

    assert_redirected_to account_settings_url(script_name: account.slug)
    assert_equal "Notification preferences saved.", flash[:notice]
    assert_predicate current_user.notification_subscriptions.find_by!(event: :invoice_reminder), :email?
    assert_not_predicate current_user.notification_subscriptions.find_by!(event: :invoice_reminder_stopped), :email?
    assert_predicate other_user.notification_subscriptions.find_by!(event: :invoice_reminder), :email?
    assert_not_predicate other_membership.notification_subscriptions.find_by!(event: :invoice_reminder), :email?

    patch account_notification_preferences_url(script_name: account.slug)

    assert_not_predicate current_user.notification_subscriptions.find_by!(event: :invoice_reminder).reload, :email?
    assert_not_predicate current_user.notification_subscriptions.find_by!(event: :invoice_reminder_stopped).reload, :email?
  end

  test "update renders invalid debtor rating rules" do
    account = sign_up_and_complete(email_address: "owner-segment-invalid@example.com")

    patch account_settings_url(script_name: account.slug), params: {
      account: {
        customer_segments_attributes: debtor_rating_attributes(
          account,
          good_debtor_rate: 50,
          bad_debtor_rate: 50
        )
      }
    }

    assert_response :unprocessable_entity
    assert_select "#flash", text: /Good Debtor on-time rate must stay above the Bad Debtor on-time rate/
    assert_equal 80, account.customer_segment(:good_debtor).reload.on_time_rate
    assert_equal 50, account.customer_segment(:bad_debtor).reload.on_time_rate
  end

  test "sign out clears session" do
    account = sign_up_and_complete

    delete session_url(script_name: nil)

    assert_redirected_to new_session_url

    get account_settings_url(script_name: account.slug)

    assert_redirected_to new_session_url(script_name: nil)
  end

  private
    def connect_gmail(account, email:)
      account.build_outbound_email_connection.connect_gmail!(
        email:,
        name: "Billing Team",
        access_token: "access-token",
        refresh_token: "refresh-token",
        expires_at: 1.hour.from_now,
        scopes: [ "email", "profile", OutboundEmailConnection::Gmailable::SEND_SCOPE ]
      )
    end

    def debtor_rating_attributes(
      account,
      good_debtor_rate: 85,
      bad_debtor_rate: 45
    )
      {
        good_debtor: {
          id: account.customer_segment(:good_debtor).id,
          on_time_rate: good_debtor_rate
        },
        bad_debtor: {
          id: account.customer_segment(:bad_debtor).id,
          on_time_rate: bad_debtor_rate
        }
      }
    end

    def sign_up_and_complete(email_address: "owner-settings@example.com", full_name: "Owner Person")
      post signup_url, params: { signup: { email_address: email_address } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: { signup: { full_name: full_name } }

      Identity.find_by!(email_address: email_address).accounts.first
    end
end

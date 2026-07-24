require "application_system_test_case"

class ConversationInboxTest < ApplicationSystemTestCase
  test "account user reviews, manually matches, and queues a threaded reply" do
    account = sign_up
    source_conversation, invoice = create_review_conversation(account)

    click_link "Inbox"

    assert_selector "h1", text: "Inbox"
    assert_selector ".app-nav-badge", text: "1"
    within ".app-conversation-row", text: "inbox-customer@example.com" do
      assert_text "Needs review"
      assert_text "Question about INV-SYSTEM-INBOX"
      click_link "inbox-customer@example.com"
    end

    assert_current_path conversation_path(
      source_conversation,
      script_name: account.slug
    )
    assert_text "Could you confirm when this invoice is due?"
    click_link "Match customer or invoice"
    select "Inbox Customer — INV-SYSTEM-INBOX", from: "Invoice"
    click_button "Match conversation"

    canonical = Conversation.for_invoice!(invoice:)
    assert_current_path conversation_path(
      canonical,
      script_name: account.slug
    )
    assert_text "Conversation matched."
    assert_text "Replying to inbox-customer@example.com"
    fill_in "Message", with: "The invoice is due next Friday."
    click_button "Send reply"

    assert_text "Reply queued."
    assert_text "The invoice is due next Friday."
    reply = canonical.conversation_messages.kind_manual_reply.sole
    assert_equal source_conversation.conversation_messages
      .kind_customer_email.sole,
      reply.reply_to_message
    assert_equal "system-inbox-thread", reply.requested_provider_thread_id
    assert_equal [ "<system-inbox-customer@example.com>" ],
      reply.in_reply_to_message_ids
    assert_equal [ "inbox-customer@example.com" ], reply.to_addresses

    click_button "Mark handled"

    assert_text "Conversation marked handled."
    assert_no_selector ".app-nav-badge"

    reply.mark_delivery_failed!(
      job_id: reply.delivery_job_id,
      failure_reason: "Gmail delivery failed."
    )
    ConversationMessages::ManualReplyOutcome.finalize!(reply)
    visit conversation_path(canonical, script_name: account.slug)

    assert_selector ".app-nav-badge", text: "1"
    click_button "Mark handled"
    assert_text "Conversation marked handled."
    assert_no_selector ".app-nav-badge"
  end

  test "account user reviews action evidence and manages holds and escalations" do
    account = sign_up
    conversation, invoice, anchor = create_action_conversation(account)
    actor = account.users.active.where.not(role: :system).sole
    conversation.update!(attention_required_at: anchor.received_at)
    Conversations::Acknowledgement.call(
      conversation:,
      actor_user: actor,
      work_unit_token: Conversations::WorkUnitSnapshot.token_for(
        conversation:
      )
    )
    ConversationActions::Proposal.record!(
      conversation:,
      source_message: anchor,
      action_type: :record_payment_promise,
      origin_kind: :user,
      created_by_user: actor,
      user_facing_summary: "Record the customer's promised payment date.",
      rationale: "The customer supplied a payment date.",
      arguments: { "promised_on" => "2026-08-15" },
      proposed_reply: {
        "subject" => "Invoice due date",
        "body" => "Your invoice is due on August 15."
      },
      idempotency_key: "system-action-proposal"
    )
    ConversationEvent.record!(
      conversation:,
      kind: :invoice_reminder_notifications_finalized,
      actor_kind: :system,
      metadata: {
        "delivered_count" => 1,
        "uncertain_count" => 1,
        "failed_count" => 1,
        "canceled_count" => 0,
        "recipient_email" => "never-render@example.com",
        "last_error_message" => "never render transport details"
      }
    )

    visit conversation_path(conversation, script_name: account.slug)

    assert_text "Record the customer's promised payment date."
    assert_selector ".app-conversation-event",
      text: "Reminder notifications finalized"
    assert_selector ".app-conversation-event",
      text: "Delivered: 1 · Unconfirmed: 1 · Failed: 1 · Canceled: 0"
    assert_no_text "never-render@example.com"
    assert_no_text "never render transport details"
    assert_text "Approval queues the exact deterministic command"
    assert_selector ".app-nav-badge", text: "1"

    find("summary", text: "Edit executable proposal").click
    fill_in "Summary", with: "Record the corrected payment date."
    date_field = find_field("Promised payment date")
    page.execute_script(
      "arguments[0].value = '2026-08-16'",
      date_field.native
    )
    fill_in "Optional greeting", with: "Hello,"
    fill_in "Optional closing", with: "Thank you."
    click_button "Save new revision"

    assert_text "Action proposal revised."
    assert_equal 2,
      conversation.conversation_actions.sole.reload.current_revision.revision_number
    fill_in "Approval note", with: "Exact revision reviewed."
    click_button "Approve revision 2"

    assert_text "The deterministic command has been queued."
    assert_no_selector ".app-nav-badge"

    action = conversation.conversation_actions.sole.reload
    invoice.update!(synced_at: Time.current)
    InvoiceReminders::InvoiceFreshnessCheck.stubs(:call).returns(invoice)
    ConversationActions::Executor.call(execution: action.execution)
    execution = action.execution.reload
    reply = execution.conversation_message
    assert_equal Date.new(2026, 8, 16),
      execution.payment_promise.promised_on
    assert_includes reply.body, "Hello,"
    reply.update!(
      status: :failed,
      failure_reason:
        ConversationMessages::ProviderDelivery::UNCONFIRMED_FAILURE_REASON,
      delivery_uncertain: true,
      provider_delivery_started_at: Time.current
    )
    ConversationMessages::ActionReplyOutcome.finalize!(reply)
    visit conversation_path(conversation, script_name: account.slug)
    assert_text "Uncertain"
    assert_text "Payment promised for"

    reply.update!(
      status: :sent,
      sent_at: Time.current,
      provider_message_id: "system-reconciled-action",
      provider_thread_id: anchor.provider_thread_id,
      failure_reason: nil,
      delivery_uncertain: false
    )
    ConversationMessages::ActionReplyOutcome.finalize!(reply)
    visit conversation_path(conversation, script_name: account.slug)
    assert_text "Succeeded"
    assert_text "August 16, 2026"

    in_flight = conversation.conversation_messages.create!(
      account:,
      invoice:,
      direction: :outbound,
      kind: :manual_reminder,
      status: :pending,
      delivery_job_id: "system-hold-in-flight",
      delivery_attempted_at: Time.current,
      provider_delivery_started_at: Time.current,
      subject: "Invoice reminder in flight",
      body: "This reminder may already be on its way."
    )
    find("summary", text: "Place a collection hold").click
    select "Manual", from: "Reason"
    fill_in "Note (optional)", with: "Pause while we verify the account."
    click_button "Pause automated collection"

    assert_text "Automated collection paused"
    warning = "An email had already started sending when this hold was placed and may still arrive."
    assert_selector ".app-collection-hold", text: warning
    assert_selector ".app-conversation-event", text: warning
    assert_text "You can still send a careful human reply."
    assert_field "Message"
    assert_predicate invoice.reload, :collection_held?

    fill_in "Release note (optional)", with: "Verification complete."
    click_button "Release hold"
    assert_text "Collection hold released."
    assert_not_predicate invoice.reload, :collection_held?

    find("summary", text: "Open an escalation").click
    select "Dispute", from: "Category"
    select "High", from: "Priority"
    fill_in "Summary", with: "Customer disputes the balance."
    fill_in "Details (optional)", with: "A person must review the invoice."
    click_button "Open escalation"

    assert_text "Conversation escalated for human review."
    assert_selector ".app-nav-badge", text: "1"

    fill_in "Resolution", with: "The customer confirmed the balance."
    click_button "Resolve escalation"
    assert_text "Escalation resolved."
    assert_no_selector ".app-nav-badge"

    click_button "Reopen escalation"
    assert_text "Escalation reopened."
    assert_selector ".app-nav-badge", text: "1"

    fill_in "Resolution", with: "A second review confirmed the correction."
    click_button "Resolve escalation"
    assert_text "Escalation resolved."
    assert_text "The customer confirmed the balance."
    assert_text "A second review confirmed the correction."
    click_button "Reopen escalation"
    assert_text "Escalation reopened."
    assert_text "The customer confirmed the balance."
    assert_text "A second review confirmed the correction."

    assert_text "Action proposal revised"
    assert_text "Action approved"
    assert_text "Automated collection paused"
    assert_text "Collection hold released"
    assert_text "Conversation escalated"
    assert_text "Escalation resolved"
    assert_text "Escalation reopened"
    assert_equal 2, conversation.conversation_events
      .kind_conversation_escalation_resolved.count
    assert_equal 2, conversation.conversation_events
      .kind_conversation_escalation_reopened.count
    assert_equal [ in_flight.id ],
      invoice.collection_holds.order(:id).last.in_flight_delivery_message_ids
  end

  private
    def sign_up
      visit new_signup_path
      fill_in "signup_email_address", with: "conversation-system@example.com"
      click_button "Let's go"
      assert_text "Check your email"
      fill_in "code", with: MagicLink.order(:created_at).last.code
      click_button "Continue"
      fill_in "signup_full_name", with: "Conversation User"
      click_button "Continue"
      assert_text "Welcome to PaymentReminder."

      Identity.find_by!(
        email_address: "conversation-system@example.com"
      ).accounts.first
    end

    def create_review_conversation(account)
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "conversation-system-source"
      )
      customer = source.customers.create!(
        account:,
        external_id: "conversation-system-customer",
        name: "Inbox Customer",
        email: "inbox-customer@example.com"
      )
      invoice = source.invoices.create!(
        account:,
        customer:,
        external_id: "conversation-system-invoice",
        number: "INV-SYSTEM-INBOX",
        status: :open
      )
      account.update!(
        invoice_reminder_from_email: "billing-system-inbox@example.com"
      )
      connection = account.create_email_connection!(
        provider: :gmail,
        provider_account_id: "system-inbox-provider",
        connected_email: account.invoice_reminder_from_email,
        access_token: "system-inbox-access-token",
        refresh_token: "system-inbox-refresh-token",
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES,
        inbound_enabled_at: 1.hour.ago,
        last_inbound_synced_at: Time.current,
        status: :active
      )
      conversation = account.conversations.create!
      message = conversation.conversation_messages.create!(
        account:,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "system-inbox-provider-message",
        provider_thread_id: "system-inbox-thread",
        internet_message_id: "<system-inbox-customer@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.current,
        from_address: customer.email,
        subject: "Question about INV-SYSTEM-INBOX",
        body: "Could you confirm when this invoice is due?",
        matching_status: :unmatched,
        matching_method: :none,
        review_required: true,
        review_reasons: [ "invoice_unmatched" ]
      )
      conversation.update!(attention_required_at: message.received_at)
      [ conversation, invoice ]
    end

    def create_action_conversation(account)
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "action-system-source"
      )
      customer = source.customers.create!(
        account:,
        external_id: "action-system-customer",
        name: "Action Customer",
        email: "action-customer@example.com"
      )
      invoice = source.invoices.create!(
        account:,
        customer:,
        external_id: "action-system-invoice",
        number: "INV-ACTION-SYSTEM",
        status: :open,
        amount_due: 125,
        due_on: Date.new(2026, 8, 15)
      )
      account.update!(
        invoice_reminder_from_email: "billing-action-system@example.com"
      )
      connection = account.create_email_connection!(
        provider: :gmail,
        provider_account_id: "action-system-provider",
        connected_email: account.invoice_reminder_from_email,
        access_token: "action-system-access-token",
        refresh_token: "action-system-refresh-token",
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES,
        inbound_enabled_at: 1.hour.ago,
        last_inbound_synced_at: Time.current,
        status: :active
      )
      conversation = Conversation.for_invoice!(invoice:)
      anchor = conversation.conversation_messages.create!(
        account:,
        invoice:,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "action-system-provider-message",
        provider_thread_id: "action-system-thread",
        internet_message_id: "<action-system-customer@example.com>",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.current,
        from_address: customer.email,
        subject: "When is this due?",
        body: "Please confirm the due date.",
        matching_status: :matched,
        matching_method: :gmail_thread
      )
      [ conversation, invoice, anchor ]
    end
end

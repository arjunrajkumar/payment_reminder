require "test_helper"

class ConversationWorkflowsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = sign_up_and_complete
    @actor = @account.users.active.where.not(role: :system).sole
    @invoice = create_invoice(@account)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @action = ConversationActions::Proposal.record!(
      conversation: @conversation,
      action_type: :answer_due_date,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Answer with the invoice due date.",
      rationale: "The customer asked when payment is due.",
      arguments: { "invoice_fact" => "due_on" },
      proposed_reply: {
        "subject" => "Invoice due date",
        "body" => "Your invoice is due on the date shown."
      },
      idempotency_key: "controller-action"
    )
  end

  test "revises and approves the exact current action revision" do
    get conversation_url(@conversation)
    revision_key = input_value("revision[idempotency_key]")
    revision_token = input_value("revision[action_snapshot]")

    post conversation_action_revisions_url(@conversation, @action), params: {
      revision: {
        user_facing_summary: "Use the reviewed due-date summary.",
        rationale: "Human corrected the wording.",
        proposed_reply_subject: "Reviewed due date",
        proposed_reply_body: "The reviewed due date is on your invoice.",
        idempotency_key: revision_key,
        action_snapshot: revision_token
      }
    }

    assert_redirected_to conversation_path(@conversation)
    assert_equal 2, @action.reload.current_revision.revision_number

    get conversation_url(@conversation)
    approval_key = input_value("approval[idempotency_key]")
    approval_token = input_value("approval[action_snapshot]")
    post conversation_action_approval_url(@conversation, @action), params: {
      approval: {
        revision_id: @action.current_revision.id,
        note: "Reviewed by a person.",
        idempotency_key: approval_key,
        action_snapshot: approval_token
      }
    }

    assert_redirected_to conversation_path(@conversation)
    assert_equal "Action approved. Nothing has been sent or executed.", flash[:notice]
    assert_predicate @action.reload, :status_approved?
    assert_equal 2, @action.decided_revision.revision_number
  end

  test "stale approval after an edit makes no partial decision" do
    get conversation_url(@conversation)
    stale_key = input_value("approval[idempotency_key]")
    stale_token = input_value("approval[action_snapshot]")
    stale_revision = @action.current_revision

    ConversationActions::Revision.record!(
      action: @action,
      author_kind: :user,
      author_user: @actor,
      user_facing_summary: "Changed after rendering.",
      rationale: nil,
      proposed_reply: {},
      idempotency_key: "concurrent-controller-revision",
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action: @action,
        idempotency_key: "concurrent-controller-revision"
      )
    )

    assert_no_difference -> {
      ConversationEvent.kind_conversation_action_approved.count
    } do
      post conversation_action_approval_url(@conversation, @action), params: {
        approval: {
          revision_id: stale_revision.id,
          idempotency_key: stale_key,
          action_snapshot: stale_token
        }
      }
    end

    assert_redirected_to conversation_path(@conversation)
    assert_equal "This action changed; refresh and try again.", flash[:alert]
    assert_predicate @action.reload, :status_pending_approval?
  end

  test "wording edit preserves unexposed proposed reply fields" do
    action = ConversationActions::Proposal.record!(
      conversation: @conversation,
      action_type: :answer_due_date,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Structured reply.",
      proposed_reply: {
        "subject" => "Original subject",
        "body" => "Original body",
        "recipient_policy" => { "include_cc" => true },
        "thread_mode" => "reply"
      },
      idempotency_key: "structured-controller-action"
    )
    key = "structured-controller-revision"

    post conversation_action_revisions_url(@conversation, action), params: {
      revision: {
        user_facing_summary: "Edited structured reply.",
        proposed_reply_subject: "Edited subject",
        proposed_reply_body: "Edited body",
        idempotency_key: key,
        action_snapshot: ConversationActions::ActionSnapshot.token_for(
          action:,
          idempotency_key: key
        )
      }
    }

    proposed_reply = action.reload.current_revision.proposed_reply
    assert_equal "Edited subject", proposed_reply["subject"]
    assert_equal "Edited body", proposed_reply["body"]
    assert_equal({ "include_cc" => true }, proposed_reply["recipient_policy"])
    assert_equal "reply", proposed_reply["thread_mode"]
  end

  test "exact wording retry uses its original base after hidden fields change" do
    action = ConversationActions::Proposal.record!(
      conversation: @conversation,
      action_type: :answer_due_date,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Retry-safe structured reply.",
      proposed_reply: {
        "subject" => "Original subject",
        "body" => "Original body",
        "policy" => { "version" => 1 }
      },
      idempotency_key: "retry-safe-controller-action"
    )
    get conversation_url(@conversation)
    key = css_select(
      "form[action='#{conversation_action_revisions_path(@conversation, action)}'] " \
        "input[name='revision[idempotency_key]']"
    ).sole.attributes.fetch("value").value
    token = css_select(
      "form[action='#{conversation_action_revisions_path(@conversation, action)}'] " \
        "input[name='revision[action_snapshot]']"
    ).sole.attributes.fetch("value").value
    base_revision_id = action.current_revision.id
    request_params = {
      revision: {
        user_facing_summary: "Edited wording.",
        rationale: "Human wording edit.",
        proposed_reply_subject: "Edited subject",
        proposed_reply_body: "Edited body",
        base_revision_id:,
        idempotency_key: key,
        action_snapshot: token
      }
    }
    post conversation_action_revisions_url(@conversation, action),
      params: request_params
    stored = action.reload.current_revision
    assert_equal({ "version" => 1 }, stored.proposed_reply["policy"])

    intervening_key = "intervening-hidden-policy"
    ConversationActions::Revision.record!(
      action:,
      author_kind: :ai,
      author_user: nil,
      user_facing_summary: "Intervening hidden policy.",
      rationale: nil,
      proposed_reply: stored.proposed_reply.deep_dup.merge(
        "policy" => { "version" => 2 }
      ),
      idempotency_key: intervening_key,
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action:,
        idempotency_key: intervening_key
      )
    )

    assert_no_difference -> { action.revisions.count } do
      post conversation_action_revisions_url(@conversation, action),
        params: request_params
    end
    assert_redirected_to conversation_path(@conversation)
    assert_equal({ "version" => 1 }, stored.reload.proposed_reply["policy"])
  end

  test "places and independently releases a hold" do
    post conversation_collection_holds_url(@conversation), params: {
      collection_hold: {
        reason: "manual",
        note: "Review before automation continues.",
        idempotency_key: "controller-hold"
      }
    }

    hold = @invoice.collection_holds.sole
    assert_redirected_to conversation_path(@conversation)
    assert_predicate hold, :status_active?

    get conversation_url(@conversation)
    post conversation_collection_hold_release_url(@conversation, hold), params: {
      release: {
        release_note: "Review complete.",
        idempotency_key: input_value("release[idempotency_key]"),
        hold_snapshot: input_value("release[hold_snapshot]")
      }
    }

    assert_redirected_to conversation_path(@conversation)
    assert_predicate hold.reload, :status_released?
  end

  test "opens resolves and reopens an escalation" do
    post conversation_escalations_url(@conversation), params: {
      escalation: {
        category: "dispute",
        priority: "high",
        summary: "Customer disputes the balance.",
        details: "A person needs to review the invoice.",
        idempotency_key: "controller-escalation"
      }
    }

    escalation = @conversation.conversation_escalations.sole
    assert_predicate escalation, :status_open?

    get conversation_url(@conversation)
    post conversation_escalation_resolution_url(
      @conversation,
      escalation
    ), params: {
      resolution: {
        resolution_note: "The balance was confirmed.",
        idempotency_key: input_value("resolution[idempotency_key]"),
        escalation_snapshot: input_value("resolution[escalation_snapshot]")
      }
    }
    assert_predicate escalation.reload, :status_resolved?

    get conversation_url(@conversation)
    post conversation_escalation_reopening_url(
      @conversation,
      escalation
    ), params: {
      reopening: {
        idempotency_key: input_value("reopening[idempotency_key]"),
        escalation_snapshot: input_value("reopening[escalation_snapshot]")
      }
    }
    assert_predicate escalation.reload, :status_open?
  end

  test "another account action and copied token are not disclosed" do
    other_conversation = Conversation.for_invoice!(invoice: invoices(:xero_invoice))
    other_action = ConversationActions::Proposal.record!(
      conversation: other_conversation,
      action_type: :other,
      origin_kind: :user,
      created_by_user: users(:arjun),
      user_facing_summary: "Other account action.",
      idempotency_key: "other-account-controller-action"
    )
    token = ConversationActions::ActionSnapshot.token_for(
      action: other_action,
      idempotency_key: "copied-token"
    )

    post conversation_action_approval_url(@conversation, other_action), params: {
      approval: {
        revision_id: other_action.current_revision.id,
        idempotency_key: "copied-token",
        action_snapshot: token
      }
    }

    assert_response :not_found
    assert_predicate other_action.reload, :status_pending_approval?
  end

  test "visible owner controls mutate workflows created before ownership changed" do
    setup_action_key = "owner-change-setup-action"
    ConversationActions::Approval.call(
      action: @action,
      revision: @action.current_revision,
      actor_user: @actor,
      idempotency_key: setup_action_key,
      snapshot_token: ConversationActions::ActionSnapshot.token_for(
        action: @action,
        idempotency_key: setup_action_key
      )
    )
    connection = @account.create_email_connection!(
      provider: :gmail,
      status: :active,
      provider_account_id: "workflow-owner-change-account",
      connected_email: "workflow-owner-change@example.com",
      access_token: "access-token",
      refresh_token: "refresh-token",
      scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
    )
    source = @account.conversations.create!
    source_message = source.conversation_messages.create!(
      account: @account,
      email_connection: connection,
      email_connection_generation: connection.credential_generation,
      provider_account_id: connection.provider_account_id,
      provider_message_id: "workflow-owner-source",
      provider_thread_id: "workflow-owner-thread",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 2.hours.ago,
      matching_status: :unmatched,
      matching_method: :none,
      review_required: true
    )
    action = ConversationActions::Proposal.record!(
      conversation: source,
      action_type: :other,
      origin_kind: :user,
      created_by_user: @actor,
      user_facing_summary: "Action on former owner.",
      idempotency_key: "former-owner-action"
    )
    escalation = ConversationEscalations::Opening.call(
      conversation: source,
      category: :ambiguous,
      priority: :high,
      summary: "Escalation on former owner.",
      opened_by_kind: :user,
      opened_by_user: @actor,
      idempotency_key: "former-owner-escalation"
    )
    invoice_message = @conversation.conversation_messages.create!(
      account: @account,
      invoice: @invoice,
      email_connection: connection,
      email_connection_generation: connection.credential_generation,
      provider_account_id: connection.provider_account_id,
      provider_message_id: "workflow-owner-invoice",
      provider_thread_id: source_message.provider_thread_id,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: 1.hour.ago,
      matching_status: :matched,
      matching_method: :gmail_thread,
      review_required: true
    )
    Conversations::Attention.require_for_message!(invoice_message)
    Conversations::Attention.recompute!(conversation: @conversation)

    get conversation_url(source)
    assert_redirected_to conversation_url(@conversation)

    get conversation_url(@conversation)
    approval_form = css_select(
      "form[action='#{conversation_action_approval_path(@conversation, action)}']"
    ).sole
    post conversation_action_approval_url(@conversation, action), params: {
      approval: {
        revision_id: action.current_revision.id,
        idempotency_key: approval_form.at_css(
          "input[name='approval[idempotency_key]']"
        )["value"],
        action_snapshot: approval_form.at_css(
          "input[name='approval[action_snapshot]']"
        )["value"]
      }
    }
    assert_predicate action.reload, :status_approved?

    get conversation_url(@conversation)
    resolution_form = css_select(
      "form[action='#{conversation_escalation_resolution_path(@conversation, escalation)}']"
    ).sole
    post conversation_escalation_resolution_url(
      @conversation,
      escalation
    ), params: {
      resolution: {
        resolution_note: "Resolved from the current owner.",
        idempotency_key: resolution_form.at_css(
          "input[name='resolution[idempotency_key]']"
        )["value"],
        escalation_snapshot: resolution_form.at_css(
          "input[name='resolution[escalation_snapshot]']"
        )["value"]
      }
    }

    assert_predicate escalation.reload, :status_resolved?
    assert_nil source.reload.attention_required_at
    assert_equal invoice_message.received_at,
      @conversation.reload.attention_required_at
  end

  private
    def input_value(name)
      css_select("input[name='#{name}']").first
        .attributes.fetch("value").value
    end

    def sign_up_and_complete
      email_address = "workflow-controller@example.com"
      post signup_url, params: { signup: { email_address: } }
      post session_magic_link_url, params: { code: MagicLink.last.code }
      post signup_completion_url, params: {
        signup: { full_name: "Workflow Owner" }
      }
      Identity.find_by!(email_address:).accounts.first
    end

    def create_invoice(account)
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: "workflow-controller-source"
      )
      customer = source.customers.create!(
        account:,
        external_id: "workflow-controller-customer",
        name: "Workflow Customer",
        email: "workflow-customer@example.com"
      )
      source.invoices.create!(
        account:,
        customer:,
        external_id: "workflow-controller-invoice",
        number: "INV-WORKFLOW",
        status: :open,
        amount_due: 100
      )
    end
end

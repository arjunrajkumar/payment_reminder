require "test_helper"
require "timeout"

class Conversations::WorkflowOwnerConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    identifiers = Thread.new { create_records }.value
    @account_id,
      @actor_id,
      @invoice_id,
      @source_conversation_id,
      @source_message_id,
      @connection_id = identifiers
  end

  teardown do
    account_id = @account_id
    Thread.new { Account.find_by(id: account_id)&.destroy! }.value if account_id
  end

  test "a proposal constructed concurrently writes to the later invoice owner" do
    action = run_after_invoice_owner_created do |source, message, actor|
      ConversationActions::Proposal.new(
        conversation: source,
        source_message: message,
        action_type: :other,
        origin_kind: :user,
        created_by_user: actor,
        user_facing_summary: "Resolve the concurrent action owner.",
        idempotency_key: "concurrent-owner-action"
      )
    end

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal owner, action.conversation
    assert_equal owner.invoice, action.current_revision.invoice
    assert_equal owner.customer, action.current_revision.customer
    assert owner.conversation_events
      .kind_conversation_action_created
      .any? { |event| event.metadata["conversation_action_id"] == action.id }
    assert owner.reload.attention_required_at
    assert_nil Conversation.find(@source_conversation_id).attention_required_at
    assert_includes Conversations::Inbox.call(account: owner.account), owner
  end

  test "an opening constructed concurrently writes to the later invoice owner" do
    escalation = run_after_invoice_owner_created do |source, message, actor|
      ConversationEscalations::Opening.new(
        conversation: source,
        source_message: message,
        category: :ambiguous,
        priority: :high,
        summary: "Resolve the concurrent escalation owner.",
        opened_by_kind: :user,
        opened_by_user: actor,
        idempotency_key: "concurrent-owner-escalation"
      )
    end

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal owner, escalation.conversation
    assert_equal owner.invoice, escalation.invoice
    assert_equal owner.customer, escalation.customer
    assert owner.conversation_events
      .kind_conversation_escalated
      .any? do |event|
        event.metadata["conversation_escalation_id"] == escalation.id
      end
    assert owner.reload.attention_required_at
    assert_nil Conversation.find(@source_conversation_id).attention_required_at
    assert_includes Conversations::Inbox.call(account: owner.account), owner
  end

  test "a proposal retries after a blocked manual match changes ownership" do
    action = run_while_manual_match_commits do |source, message, actor|
      ConversationActions::Proposal.new(
        conversation: source,
        source_message: message,
        action_type: :other,
        origin_kind: :user,
        created_by_user: actor,
        user_facing_summary: "Retry the action under the committed owner.",
        idempotency_key: "blocked-owner-action"
      )
    end

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal owner, action.conversation
    assert_equal owner.invoice, action.current_revision.invoice
    assert_equal owner.customer, action.current_revision.customer
    assert_equal 1, owner.conversation_actions
      .where(idempotency_key: "blocked-owner-action").count
    assert owner.conversation_events
      .kind_conversation_action_created
      .any? { |event| event.metadata["conversation_action_id"] == action.id }
    assert owner.reload.attention_required_at
    assert_nil Conversation.find(@source_conversation_id).attention_required_at
    assert_includes Conversations::Inbox.call(account: owner.account), owner
  end

  test "an opening retries after a blocked manual match changes ownership" do
    escalation = run_while_manual_match_commits do |source, message, actor|
      ConversationEscalations::Opening.new(
        conversation: source,
        source_message: message,
        category: :ambiguous,
        priority: :high,
        summary: "Retry the escalation under the committed owner.",
        opened_by_kind: :user,
        opened_by_user: actor,
        idempotency_key: "blocked-owner-escalation"
      )
    end

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal owner, escalation.conversation
    assert_equal owner.invoice, escalation.invoice
    assert_equal owner.customer, escalation.customer
    assert_equal 1, owner.conversation_escalations
      .where(idempotency_key: "blocked-owner-escalation").count
    assert owner.conversation_events
      .kind_conversation_escalated
      .any? do |event|
        event.metadata["conversation_escalation_id"] == escalation.id
      end
    assert owner.reload.attention_required_at
    assert_nil Conversation.find(@source_conversation_id).attention_required_at
    assert_includes Conversations::Inbox.call(account: owner.account), owner
  end

  test "an ambient transaction proposal refreshes its owner after manual match" do
    action = run_while_manual_match_commits(
      ambient: true,
      establish_snapshot: true
    ) do |source, message, actor|
      ConversationActions::Proposal.new(
        conversation: source,
        source_message: message,
        action_type: :other,
        origin_kind: :user,
        created_by_user: actor,
        user_facing_summary: "Refresh the ambient action owner.",
        idempotency_key: "ambient-owner-action"
      )
    end

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal owner, action.conversation
    assert_equal owner.invoice, action.current_revision.invoice
    assert_equal owner.customer, action.current_revision.customer
    assert_equal 1, owner.conversation_actions
      .where(idempotency_key: "ambient-owner-action").count
    assert_equal 1, owner.conversation_events
      .kind_conversation_action_created
      .count do |event|
        event.metadata["conversation_action_id"] == action.id
      end
    assert owner.reload.attention_required_at
  end

  test "an ambient transaction opening refreshes its owner after manual match" do
    escalation = run_while_manual_match_commits(
      ambient: true,
      establish_snapshot: true
    ) do |source, message, actor|
      ConversationEscalations::Opening.new(
        conversation: source,
        source_message: message,
        category: :ambiguous,
        priority: :high,
        summary: "Refresh the ambient escalation owner.",
        opened_by_kind: :user,
        opened_by_user: actor,
        idempotency_key: "ambient-owner-escalation"
      )
    end

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal owner, escalation.conversation
    assert_equal owner.invoice, escalation.invoice
    assert_equal owner.customer, escalation.customer
    assert_equal 1, owner.conversation_escalations
      .where(idempotency_key: "ambient-owner-escalation").count
    assert_equal 1, owner.conversation_events
      .kind_conversation_escalated
      .count do |event|
        event.metadata["conversation_escalation_id"] == escalation.id
      end
    assert owner.reload.attention_required_at
  end

  test "an ambient proposal sees the caller's uncommitted invoice owner message" do
    action = nil
    replay = nil
    Conversation.transaction do
      create_invoice_owner_message
      source = Conversation.find(@source_conversation_id)
      message = ConversationMessage.find(@source_message_id)
      attributes = {
        conversation: source,
        source_message: message,
        action_type: :other,
        origin_kind: :user,
        created_by_user: User.find(@actor_id),
        user_facing_summary: "Use the uncommitted invoice owner.",
        idempotency_key: "uncommitted-owner-action"
      }
      action = ConversationActions::Proposal.record!(**attributes)
      replay = ConversationActions::Proposal.record!(**attributes)
    end

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal action, replay
    assert_equal owner, action.reload.conversation
    assert_equal owner.invoice, action.current_revision.invoice
    assert_equal owner.customer, action.current_revision.customer
    assert_equal 1, owner.conversation_events
      .kind_conversation_action_created
      .count { _1.metadata["conversation_action_id"] == action.id }
    assert owner.reload.attention_required_at
  end

  test "an ambient opening sees the caller's uncommitted invoice owner message" do
    escalation = nil
    replay = nil
    Conversation.transaction do
      create_invoice_owner_message
      attributes = {
        conversation: Conversation.find(@source_conversation_id),
        source_message: ConversationMessage.find(@source_message_id),
        category: :ambiguous,
        priority: :high,
        summary: "Use the uncommitted invoice owner.",
        opened_by_kind: :user,
        opened_by_user: User.find(@actor_id),
        idempotency_key: "uncommitted-owner-escalation"
      }
      escalation = ConversationEscalations::Opening.call(**attributes)
      replay = ConversationEscalations::Opening.call(**attributes)
    end

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal escalation, replay
    assert_equal owner, escalation.reload.conversation
    assert_equal owner.invoice, escalation.invoice
    assert_equal owner.customer, escalation.customer
    assert_equal 1, owner.conversation_events
      .kind_conversation_escalated
      .count { _1.metadata["conversation_escalation_id"] == escalation.id }
    assert owner.reload.attention_required_at
  end

  test "an ambient proposal supports a newly created uncommitted conversation" do
    action = nil
    replay = nil
    Conversation.transaction do
      source, message = create_uncommitted_source("new-action")
      attributes = {
        conversation: source,
        source_message: message,
        action_type: :other,
        origin_kind: :user,
        created_by_user: User.find(@actor_id),
        user_facing_summary: "Record on a new conversation.",
        idempotency_key: "new-uncommitted-action"
      }
      action = ConversationActions::Proposal.record!(**attributes)
      replay = ConversationActions::Proposal.record!(**attributes)
    end

    assert_equal action, replay
    assert_equal action.conversation_id, action.reload.conversation.id
    assert_nil action.current_revision.invoice
    assert_nil action.current_revision.customer
    assert_equal 1, action.conversation.conversation_events
      .kind_conversation_action_created
      .count { _1.metadata["conversation_action_id"] == action.id }
    assert action.conversation.reload.attention_required_at
  end

  test "an ambient opening supports a newly created uncommitted conversation" do
    escalation = nil
    replay = nil
    Conversation.transaction do
      source, message = create_uncommitted_source("new-escalation")
      attributes = {
        conversation: source,
        source_message: message,
        category: :ambiguous,
        priority: :high,
        summary: "Escalate a new conversation.",
        opened_by_kind: :user,
        opened_by_user: User.find(@actor_id),
        idempotency_key: "new-uncommitted-escalation"
      }
      escalation = ConversationEscalations::Opening.call(**attributes)
      replay = ConversationEscalations::Opening.call(**attributes)
    end

    assert_equal escalation, replay
    assert_equal escalation.conversation_id, escalation.reload.conversation.id
    assert_nil escalation.invoice
    assert_nil escalation.customer
    assert_equal 1, escalation.conversation.conversation_events
      .kind_conversation_escalated
      .count { _1.metadata["conversation_escalation_id"] == escalation.id }
    assert escalation.conversation.reload.attention_required_at
  end

  test "a stale ambient snapshot transfers a sourced action before proposal replay" do
    source = Conversation.find(@source_conversation_id)
    message = ConversationMessage.find(@source_message_id)
    original = ConversationActions::Proposal.record!(
      conversation: source,
      source_message: message,
      action_type: :other,
      origin_kind: :user,
      created_by_user: User.find(@actor_id),
      user_facing_summary: "Transfer this sourced action.",
      idempotency_key: "stale-transfer-original-action"
    )

    created = run_after_stale_snapshot_owner_commit do |current, evidence, actor|
      ConversationActions::Proposal.record!(
        conversation: current,
        source_message: evidence,
        action_type: :other,
        origin_kind: :user,
        created_by_user: actor,
        user_facing_summary: "Create after current-read reconciliation.",
        idempotency_key: "stale-transfer-new-action"
      )
    end
    replay = ConversationActions::Proposal.record!(
      conversation: source,
      source_message: message,
      action_type: :other,
      origin_kind: :user,
      created_by_user: User.find(@actor_id),
      user_facing_summary: "Create after current-read reconciliation.",
      idempotency_key: "stale-transfer-new-action"
    )

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal owner, original.reload.conversation
    assert_equal owner, created.conversation
    assert_equal created, replay
    assert_equal 1, owner.conversation_actions
      .where(idempotency_key: "stale-transfer-new-action").count
  end

  test "a stale ambient snapshot transfers a sourced escalation before opening" do
    source = Conversation.find(@source_conversation_id)
    message = ConversationMessage.find(@source_message_id)
    original = ConversationEscalations::Opening.call(
      conversation: source,
      source_message: message,
      category: :ambiguous,
      priority: :high,
      summary: "Transfer this sourced escalation.",
      opened_by_kind: :user,
      opened_by_user: User.find(@actor_id),
      idempotency_key: "stale-transfer-original-escalation"
    )

    created = run_after_stale_snapshot_owner_commit do |current, evidence, actor|
      ConversationEscalations::Opening.call(
        conversation: current,
        source_message: evidence,
        category: :ambiguous,
        priority: :high,
        summary: "Open after current-read reconciliation.",
        opened_by_kind: :user,
        opened_by_user: actor,
        idempotency_key: "stale-transfer-new-escalation"
      )
    end

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal owner, original.reload.conversation
    assert_equal owner, created.conversation
    assert_equal created, ConversationEscalations::Opening.call(
      conversation: source,
      source_message: message,
      category: :ambiguous,
      priority: :high,
      summary: "Open after current-read reconciliation.",
      opened_by_kind: :user,
      opened_by_user: User.find(@actor_id),
      idempotency_key: "stale-transfer-new-escalation"
    )
  end

  test "a stale ambient snapshot transfers sourced workflow before placement" do
    source = Conversation.find(@source_conversation_id)
    message = ConversationMessage.find(@source_message_id)
    action = ConversationActions::Proposal.record!(
      conversation: source,
      source_message: message,
      action_type: :other,
      origin_kind: :user,
      created_by_user: User.find(@actor_id),
      user_facing_summary: "Hold this transferred action.",
      idempotency_key: "stale-transfer-hold-action"
    )

    hold = run_after_stale_snapshot_owner_commit do |current, evidence, actor|
      CollectionHolds::Placement.call(
        conversation: current,
        source_message: evidence,
        conversation_action: action,
        reason: :manual,
        placed_by_kind: :user,
        placed_by_user: actor,
        idempotency_key: "stale-transfer-hold"
      )
    end

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    assert_equal owner, action.reload.conversation
    assert_equal owner, hold.conversation
    assert_equal hold, CollectionHolds::Placement.call(
      conversation: source,
      source_message: message,
      conversation_action: action,
      reason: :manual,
      placed_by_kind: :user,
      placed_by_user: User.find(@actor_id),
      idempotency_key: "stale-transfer-hold"
    )
    assert_equal 1, owner.conversation_events
      .kind_collection_hold_placed.count
  end

  test "placement and a different Gmail thread manual match avoid lock cycles" do
    source = Conversation.find(@source_conversation_id)
    message = ConversationMessage.find(@source_message_id)
    actor = User.find(@actor_id)
    action = ConversationActions::Proposal.record!(
      conversation: source,
      source_message: message,
      action_type: :other,
      origin_kind: :user,
      created_by_user: actor,
      user_facing_summary: "Place a hold while matching.",
      idempotency_key: "concurrent-match-hold-action"
    )
    create_invoice_owner_message
    manual_source = source.account.conversations.create!
    manual_message = manual_source.conversation_messages.create!(
      account: source.account,
      email_connection: EmailConnection.find(@connection_id),
      email_connection_generation: message.email_connection_generation,
      provider_account_id: message.provider_account_id,
      provider_message_id: "different-thread-manual-match",
      provider_thread_id: "different-thread-manual-match",
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current,
      matching_status: :unmatched,
      matching_method: :none,
      review_required: true
    )
    token = Conversations::WorkUnitSnapshot.token_for(
      conversation: manual_source
    )
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = [
      Thread.new do
        ready << true
        start.pop
        results << CollectionHolds::Placement.call(
          conversation: Conversation.find(@source_conversation_id),
          conversation_action: ConversationAction.find(action.id),
          reason: :manual,
          placed_by_kind: :user,
          placed_by_user: User.find(@actor_id),
          idempotency_key: "concurrent-match-hold"
        )
      rescue StandardError => error
        results << error
      end,
      Thread.new do
        ready << true
        start.pop
        results << Conversations::ManualMatcher.call(
          source_conversation: Conversation.find(manual_source.id),
          reviewed_message: ConversationMessage.find(manual_message.id),
          target_invoice: Invoice.find(@invoice_id),
          actor_user: User.find(@actor_id),
          work_unit_token: token
        )
      rescue StandardError => error
        results << error
      end
    ]
    2.times { Timeout.timeout(2) { ready.pop } }
    2.times { start << true }

    values = 2.times.map { Timeout.timeout(10) { results.pop } }
    threads.each { |thread| Timeout.timeout(10) { thread.join } }
    errors = values.grep(Exception)
    assert_empty errors, errors.map(&:full_message).join("\n")

    owner = Conversation.for_invoice!(invoice: Invoice.find(@invoice_id))
    hold = values.find { _1.is_a?(CollectionHold) }
    match = values.find { _1.is_a?(Conversation) }
    assert_equal owner, match
    assert_equal owner, hold.conversation
    assert_equal owner, action.reload.conversation
    assert_equal 1, owner.collection_holds
      .where(idempotency_key: "concurrent-match-hold").count
    assert_equal 1, owner.conversation_events
      .kind_collection_hold_placed
      .count { _1.metadata["collection_hold_id"] == hold.id }
    assert_equal 1, owner.conversation_events
      .kind_conversation_manually_matched.count
  end

  test "placement and scheduled reservation preserve the authoritative winner" do
    account = Account.find(@account_id)
    invoice = Invoice.find(@invoice_id)
    actor = User.find(@actor_id)
    connection = EmailConnection.find(@connection_id)
    account.update_columns(
      automatic_invoice_reminders_enabled: true,
      invoice_reminder_from_email: connection.connected_email
    )
    invoice.update!(
      issued_on: Date.new(2026, 7, 1),
      due_on: Date.new(2026, 7, 31)
    )
    account.invoice_schedules.find_or_create_by!(
      kind: :normal_debtor,
      category: :pre_due,
      day_offset: 7
    ) { |schedule| schedule.tone = :friendly }
    owner = Conversation.for_invoice!(invoice:)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = [
      Thread.new do
        ready << true
        start.pop
        results << CollectionHolds::Placement.call(
          conversation: Conversation.find(owner.id),
          reason: :manual,
          placed_by_kind: :user,
          placed_by_user: User.find(actor.id),
          idempotency_key: "reservation-lock-order-hold"
        )
      rescue StandardError => error
        results << error
      end,
      Thread.new do
        ready << true
        start.pop
        results << InvoiceReminders::DeliveryReservation.call(
          invoice: Invoice.find(invoice.id),
          category: :pre_due,
          day_offset: 7,
          delivery_job_id: "reservation-lock-order",
          on: Date.new(2026, 7, 24)
        )
      rescue StandardError => error
        results << error
      end
    ]
    2.times { Timeout.timeout(2) { ready.pop } }
    2.times { start << true }

    values = 2.times.map { Timeout.timeout(10) { results.pop } }
    threads.each { |thread| Timeout.timeout(10) { thread.join } }
    errors = values.grep(Exception)
    assert_empty errors, errors.map(&:full_message).join("\n")

    hold = values.find { _1.is_a?(CollectionHold) }
    reservation = values.find do |value|
      value.is_a?(InvoiceReminders::DeliveryReservation::Result)
    end
    assert_equal 1, invoice.collection_holds
      .where(idempotency_key: "reservation-lock-order-hold").count
    if reservation.reserved?
      claim = InvoiceReminders::FinalDeliveryClaim.call(
        invoice:,
        reminder: reservation.reminder,
        delivery_job_id: "reservation-lock-order"
      )
      assert_equal "active_collection_hold", claim.reason
      assert_predicate reservation.reminder.conversation_message.reload,
        :status_failed?
    else
      assert_equal "active_collection_hold", reservation.reason
    end
    assert_equal hold, invoice.active_collection_holds.sole
  end

  private
    def run_while_manual_match_commits(
      ambient: false,
      establish_snapshot: false
    )
      connection_ready = Queue.new
      result = Queue.new
      worker = nil
      source = Conversation.find(@source_conversation_id)
      message = ConversationMessage.find(@source_message_id)
      token = Conversations::WorkUnitSnapshot.token_for(conversation: source)
      EmailConnection::MailboxThreadLock.synchronize(
        account: source.account,
        provider_account_id: message.provider_account_id,
        provider_thread_id: message.provider_thread_id
      ) do
        worker = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            connection_ready << connection.select_value(
              "SELECT CONNECTION_ID()"
            )
            service = yield(
              Conversation.find(@source_conversation_id),
              ConversationMessage.find(@source_message_id),
              User.find(@actor_id)
            )
            operation = -> {
              service.public_send(
                service.is_a?(ConversationActions::Proposal) ? :record! : :call
              )
            }
            result << if ambient
              Conversation.transaction do
                if establish_snapshot
                  Conversation.where(account_id: @account_id).pluck(:id)
                end
                operation.call
              end
            else
              operation.call
            end
          end
        rescue StandardError => error
          result << error
        end
        Timeout.timeout(2) { connection_ready.pop }
        wait_for_workflow_block(worker:, result:)
        Conversations::ManualMatcher.call(
          source_conversation: source,
          reviewed_message: message,
          target_invoice: Invoice.find(@invoice_id),
          actor_user: User.find(@actor_id),
          work_unit_token: token
        )
      end

      value = Timeout.timeout(5) { result.pop }
      Timeout.timeout(5) { worker.join }
      raise value if value.is_a?(Exception)

      value
    end

    def wait_for_workflow_block(worker:, result:)
      Timeout.timeout(5) do
        loop do
          unless worker.alive?
            value = result.pop
            raise value if value.is_a?(Exception)

            raise "Workflow operation finished before the expected lock wait."
          end
          lock_entries = EmailConnection::MailboxThreadLock
            .send(:local_locks).values
          break if lock_entries.any? { _1[:users] >= 2 }

          sleep 0.01
        end
      end
    rescue Timeout::Error
      raise "Expected the workflow operation to wait for its mailbox lock."
    end

    def run_after_invoice_owner_created
      constructed = Queue.new
      continue = Queue.new
      result = Queue.new
      worker = Thread.new do
        service = yield(
          Conversation.find(@source_conversation_id),
          ConversationMessage.find(@source_message_id),
          User.find(@actor_id)
        )
        constructed << true
        continue.pop
        result << service.public_send(
          service.is_a?(ConversationActions::Proposal) ? :record! : :call
        )
      rescue StandardError => error
        result << error
      end

      Timeout.timeout(2) { constructed.pop }
      create_invoice_owner_message
      continue << true
      value = Timeout.timeout(5) { result.pop }
      Timeout.timeout(5) { worker.join }
      raise value if value.is_a?(Exception)

      value
    end

    def run_after_stale_snapshot_owner_commit
      snapshot_ready = Queue.new
      continue = Queue.new
      result = Queue.new
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          value = Conversation.transaction do
            Conversation.where(account_id: @account_id).pluck(:id)
            snapshot_ready << true
            continue.pop
            yield(
              Conversation.find(@source_conversation_id),
              ConversationMessage.find(@source_message_id),
              User.find(@actor_id)
            )
          end
          result << value
        end
      rescue StandardError => error
        result << error
      end

      Timeout.timeout(2) { snapshot_ready.pop }
      create_invoice_owner_message
      continue << true
      value = Timeout.timeout(5) { result.pop }
      Timeout.timeout(5) { worker.join }
      raise value if value.is_a?(Exception)

      value
    ensure
      continue << true if worker&.alive?
      worker&.join
    end

    def create_records
      account = Account.create!(name: "Workflow owner #{SecureRandom.uuid}")
      actor = account.users.create!(name: "Workflow owner actor", role: :owner)
      connection = account.create_email_connection!(
        provider: :gmail,
        status: :active,
        provider_account_id: "workflow-owner-#{SecureRandom.uuid}",
        connected_email: "workflow-owner@example.com",
        access_token: "workflow-owner-access",
        refresh_token: "workflow-owner-refresh",
        token_expires_at: 1.year.from_now,
        scopes: EmailConnection::Gmailable::REQUIRED_SCOPES
      )
      source = account.invoice_sources.create!(
        provider: :xero,
        status: :active,
        external_account_id: SecureRandom.uuid
      )
      customer = source.customers.create!(
        account:,
        external_id: SecureRandom.uuid,
        name: "Workflow owner customer",
        email: "workflow-owner-customer@example.com"
      )
      invoice = source.invoices.create!(
        account:,
        customer:,
        external_id: SecureRandom.uuid,
        status: :open,
        amount_due: 100
      )
      conversation = account.conversations.create!
      message = conversation.conversation_messages.create!(
        account:,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "workflow-source-#{SecureRandom.uuid}",
        provider_thread_id: "workflow-owner-thread",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.current,
        matching_status: :unmatched,
        matching_method: :none,
        review_required: true
      )
      conversation.update!(attention_required_at: message.received_at)
      [
        account.id,
        actor.id,
        invoice.id,
        conversation.id,
        message.id,
        connection.id
      ]
    end

    def create_invoice_owner_message
      invoice = Invoice.find(@invoice_id)
      connection = EmailConnection.find(@connection_id)
      owner = Conversation.for_invoice!(invoice:)
      owner.conversation_messages.create!(
        account: invoice.account,
        invoice:,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "workflow-owner-#{SecureRandom.uuid}",
        provider_thread_id: "workflow-owner-thread",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: 1.minute.from_now,
        matching_status: :matched,
        matching_method: :gmail_thread,
        review_required: true
      )
    end

    def create_uncommitted_source(suffix)
      account = Account.find(@account_id)
      connection = EmailConnection.find(@connection_id)
      conversation = account.conversations.create!
      message = conversation.conversation_messages.create!(
        account:,
        email_connection: connection,
        email_connection_generation: connection.credential_generation,
        provider_account_id: connection.provider_account_id,
        provider_message_id: "uncommitted-#{suffix}-#{SecureRandom.uuid}",
        provider_thread_id: "uncommitted-#{suffix}-#{SecureRandom.uuid}",
        direction: :inbound,
        kind: :customer_email,
        status: :received,
        received_at: Time.current,
        matching_status: :unmatched,
        matching_method: :none,
        review_required: true
      )
      conversation.update!(attention_required_at: message.received_at)
      [ conversation, message ]
    end
end

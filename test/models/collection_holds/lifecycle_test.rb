require "test_helper"

class CollectionHolds::LifecycleTest < ActiveSupport::TestCase
  setup do
    @invoice = invoices(:xero_invoice)
    @conversation = Conversation.for_invoice!(invoice: @invoice)
    @actor = users(:arjun)
  end

  test "multiple independent holds coexist and releasing one leaves the other active" do
    manual = place_hold(reason: :manual, idempotency_key: "manual-hold")
    dispute = place_hold(reason: :dispute, idempotency_key: "dispute-hold")

    assert_predicate @invoice.reload, :collection_held?
    assert_equal [ manual, dispute ].sort_by(&:id),
      @invoice.active_collection_holds.reorder(:id).to_a

    token = CollectionHolds::HoldSnapshot.token_for(
      hold: manual,
      idempotency_key: "release-manual"
    )
    manual.release!(
      actor_user: @actor,
      release_note: "Manual review complete.",
      idempotency_key: "release-manual",
      snapshot_token: token
    )

    assert_predicate manual.reload, :status_released?
    assert_predicate dispute.reload, :status_active?
    assert_predicate @invoice.reload, :collection_held?
  end

  test "placement and release retries are idempotent and audited once" do
    first = place_hold

    assert_no_difference [
      -> { CollectionHold.count },
      -> { ConversationEvent.kind_collection_hold_placed.count }
    ] do
      assert_equal first, place_hold
    end

    token = CollectionHolds::HoldSnapshot.token_for(
      hold: first,
      idempotency_key: "release-hold"
    )
    2.times do
      first.release!(
        actor_user: @actor,
        release_note: "Released safely.",
        idempotency_key: "release-hold",
        snapshot_token: token
      )
    end

    assert_equal 1, @conversation.conversation_events
      .kind_collection_hold_released.count
  end

  test "a hold creates a paused state without permanent attention by itself" do
    place_hold

    Conversations::Attention.recompute!(conversation: @conversation)

    assert_nil @conversation.reload.attention_required_at
    assert_predicate @invoice.reload, :collection_held?
  end

  test "historical customer snapshot survives invoice customer correction and retries" do
    hold = place_hold(idempotency_key: "snapshot-hold")
    original_customer = hold.customer
    replacement = @invoice.invoice_source.customers.create!(
      account: @invoice.account,
      external_id: "corrected-hold-customer",
      name: "Corrected hold customer",
      email: "corrected-hold@example.com"
    )
    @invoice.update!(customer: replacement)

    assert_equal hold, place_hold(idempotency_key: "snapshot-hold")
    release_key = "release-corrected-customer-hold"
    token = CollectionHolds::HoldSnapshot.token_for(
      hold:,
      idempotency_key: release_key
    )
    2.times do
      hold.release!(
        actor_user: @actor,
        release_note: "Reviewed after correction.",
        idempotency_key: release_key,
        snapshot_token: token
      )
    end

    assert_equal original_customer, hold.reload.customer
    assert_predicate hold, :status_released?
  end

  test "direct updates cannot rewrite hold provenance or lifecycle" do
    hold = place_hold

    assert_raises ActiveRecord::ReadOnlyRecord do
      hold.update!(reason: :other)
    end
    assert_raises ActiveRecord::ReadOnlyRecord do
      hold.update!(
        status: :released,
        released_by_user: @actor,
        released_at: Time.current,
        release_note: "Bypassed audit.",
        release_idempotency_key: "bypassed"
      )
    end
  end

  test "multiple holds can cite one source message with complete audit events" do
    source_message = @invoice.conversation_messages.create!(
      account: @invoice.account,
      conversation: @conversation,
      direction: :inbound,
      kind: :customer_email,
      status: :received,
      received_at: Time.current
    )
    2.times do |index|
      CollectionHolds::Placement.call(
        conversation: @conversation,
        source_message:,
        reason: :manual,
        placed_by_kind: :user,
        placed_by_user: @actor,
        idempotency_key: "same-source-hold-#{index}"
      )
    end

    assert_equal 2, @conversation.conversation_events
      .kind_collection_hold_placed.count
    assert_empty @conversation.conversation_events
      .kind_collection_hold_placed
      .where.not(conversation_message_id: nil)
  end

  test "validation bypass and public parent deletion cannot bypass hold audit" do
    hold = place_hold
    hold.status = :released
    hold.released_by_user = @actor
    hold.released_at = Time.current
    hold.release_idempotency_key = "validation-bypass"

    assert_raises ActiveRecord::ReadOnlyRecord do
      hold.save!(validate: false)
    end
    assert_raises NoMethodError do
      hold.destroy_for_parent!
    end
    assert_predicate hold.reload, :status_active?
    assert_empty @conversation.conversation_events
      .kind_collection_hold_released
  end

  private
    def place_hold(reason: :manual, idempotency_key: "hold-one")
      CollectionHolds::Placement.call(
        conversation: @conversation,
        reason:,
        note: "Pause automated collection.",
        placed_by_kind: :user,
        placed_by_user: @actor,
        idempotency_key:
      )
    end
end

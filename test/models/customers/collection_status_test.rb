require "test_helper"

class Customers::CollectionStatusTest < ActiveSupport::TestCase
  test "is paid when no outstanding invoices remain" do
    status = status_for(outstanding: 0, overdue: 0, state: :waiting, needs_attention: true)

    assert_equal Customers::CollectionStatus::STATUSES.fetch(:paid), status
  end

  test "is unpaid when an overdue collection has stalled without a reply" do
    status = status_for(outstanding: 1, overdue: 1, state: :no_reply, needs_attention: true)

    assert_equal Customers::CollectionStatus::STATUSES.fetch(:unpaid), status
  end

  test "needs attention when an active exception needs a decision" do
    status = status_for(outstanding: 1, overdue: 1, state: :dispute, needs_attention: true)

    assert_equal Customers::CollectionStatus::STATUSES.fetch(:needs_attention), status
  end

  test "remains in progress while collection is moving normally" do
    waiting = status_for(outstanding: 1, overdue: 1, state: :waiting, needs_attention: false)
    pre_due_no_reply = status_for(outstanding: 1, overdue: 0, state: :no_reply, needs_attention: true)

    assert_equal Customers::CollectionStatus::STATUSES.fetch(:in_progress), waiting
    assert_equal Customers::CollectionStatus::STATUSES.fetch(:in_progress), pre_due_no_reply
  end

  private
    def status_for(outstanding:, overdue:, state:, needs_attention:)
      customer = Struct.new(:outstanding_invoices, :overdue_invoices, keyword_init: true).new(
        outstanding_invoices: Array.new(outstanding) { Object.new },
        overdue_invoices: Array.new(overdue) { Object.new }
      )

      Customers::CollectionStatus.new(
        customer,
        collection_state: state,
        needs_attention: needs_attention
      ).to_h
    end
end

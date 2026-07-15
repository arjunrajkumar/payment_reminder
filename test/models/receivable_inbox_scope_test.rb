require "test_helper"

class ReceivableInboxScopeTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:paid_jar)
    @source = invoice_sources(:xero)
    @as_of = Date.new(2026, 7, 15)

    @overdue = create_receivable(name: "Overdue", status: :outstanding, due_on: @as_of - 1.day)
    @outstanding = create_receivable(name: "Outstanding", status: :outstanding, due_on: @as_of)
    @undated = create_receivable(name: "Undated", status: :outstanding, due_on: nil)
    @paid = create_receivable(name: "Paid", status: :paid, due_on: @as_of - 1.month)
    @uncollectible = create_receivable(name: "Uncollectible", status: :uncollectible, due_on: @as_of - 1.month)
    create_receivable(name: "Inactive", status: :none, due_on: nil)
  end

  test "for inbox returns every active receivable in display order" do
    receivables = @account.receivables.for_inbox(as_of: @as_of)

    assert_kind_of ActiveRecord::Relation, receivables
    assert_equal [ @overdue, @outstanding, @undated, @paid, @uncollectible ], receivables.to_a
  end

  private
    def create_receivable(name:, status:, due_on:)
      customer = @source.customers.create!(
        account: @account,
        external_id: SecureRandom.uuid,
        name: name
      )

      @account.receivables.create!(
        customer: customer,
        status: status,
        due_on: due_on,
        calculated_at: Time.current
      )
    end
end

class Customers::CollectionStatus
  # A deliberately small view of whether collection is moving normally. Email
  # activity and customer updates explain the status, but do not become more
  # statuses themselves.
  STATUSES = {
    in_progress: {
      label: "In progress",
      tone: "in-progress",
      rule: "The balance is open and collection is moving normally"
    },
    needs_attention: {
      label: "Needs attention",
      tone: "needs-attention",
      rule: "The balance is open and an exception needs a decision"
    },
    unpaid: {
      label: "Unpaid",
      tone: "unpaid",
      rule: "The balance remains open after collection has stalled"
    },
    open: {
      label: "Open",
      tone: "open",
      rule: "The provider still marks an invoice open, but no balance is due"
    },
    uncollectible: {
      label: "Uncollectible",
      tone: "uncollectible",
      rule: "At least one invoice is marked uncollectible and no invoices remain open"
    },
    paid: {
      label: "Paid",
      tone: "paid",
      rule: "No outstanding balance remains"
    }
  }.freeze

  UNPAID_COLLECTION_STATES = [ :no_reply ].freeze

  def initialize(customer, collection_state:, needs_attention:)
    @customer = customer
    @collection_state = collection_state.to_sym
    @needs_attention = needs_attention
  end

  def to_h
    status
  end

  private
    attr_reader :collection_state, :customer, :needs_attention

    def key
      @key ||= if customer.outstanding_invoices.any?
        active_collection_key
      elsif customer.open_invoices.any?
        :open
      elsif customer.uncollectible_invoices.any?
        :uncollectible
      else
        :paid
      end
    end

    def active_collection_key
      if collection_stalled_unpaid?
        :unpaid
      elsif attention_required?
        :needs_attention
      else
        :in_progress
      end
    end

    def collection_stalled_unpaid?
      UNPAID_COLLECTION_STATES.include?(collection_state) && customer.overdue_invoices.any?
    end

    def attention_required?
      needs_attention && !UNPAID_COLLECTION_STATES.include?(collection_state)
    end

    def status
      STATUSES.fetch(key)
    end
end

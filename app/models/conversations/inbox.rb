class Conversations::Inbox
  FILTERS = %w[all needs_attention needs_review].freeze

  Entry = Data.define(
    :conversation,
    :latest_message,
    :latest_inbound_sender,
    :needs_review,
    :collection_held,
    :latest_activity_at,
    :workflow_summary
  )

  class << self
    def call(account:, filter: :all)
      new(account:, filter:).relation
    end

    def decorate(account:, conversations:)
      records = conversations.to_a
      return [] if records.empty?

      root_by_conversation_id = grouped_conversation_ids(
        account:,
        root_ids: records.map(&:id)
      )
      review_root_ids = account.conversation_messages
        .where(conversation_id: root_by_conversation_id.keys)
        .awaiting_review
        .distinct
        .pluck(:conversation_id)
        .filter_map { |conversation_id| root_by_conversation_id[conversation_id] }
        .to_set
      latest_by_root = latest_messages_by_root(
        account:,
        root_by_conversation_id:
      )
      latest_inbound_by_root = latest_messages_by_root(
        account:,
        root_by_conversation_id:,
        direction: :inbound
      )
      workflow_conversation_ids = root_by_conversation_id.keys
      held_root_ids = account.collection_holds
        .status_active
        .where(conversation_id: workflow_conversation_ids)
        .distinct
        .pluck(:conversation_id)
        .filter_map { |id| root_by_conversation_id[id] }
        .to_set
      actions_by_root = account.conversation_actions
        .where(conversation_id: workflow_conversation_ids)
        .includes(:revisions)
        .group_by { |action| root_by_conversation_id[action.conversation_id] }
      escalations_by_root = account.conversation_escalations
        .where(conversation_id: workflow_conversation_ids)
        .group_by { |escalation| root_by_conversation_id[escalation.conversation_id] }
      holds_by_root = account.collection_holds
        .where(conversation_id: workflow_conversation_ids)
        .group_by { |hold| root_by_conversation_id[hold.conversation_id] }

      records.map do |conversation|
        latest_message = latest_by_root[conversation.id]
        workflow_item = latest_workflow_item(
          actions: actions_by_root[conversation.id],
          escalations: escalations_by_root[conversation.id],
          holds: holds_by_root[conversation.id]
        )
        Entry.new(
          conversation:,
          latest_message:,
          latest_inbound_sender: latest_inbound_by_root[conversation.id]&.from_address,
          needs_review: review_root_ids.include?(conversation.id),
          collection_held: held_root_ids.include?(conversation.id),
          latest_activity_at: [
            latest_message&.occurred_at,
            workflow_item&.fetch(:occurred_at)
          ].compact.max,
          workflow_summary: workflow_item&.fetch(:summary)
        )
      end
    end

    private
      def grouped_conversation_ids(account:, root_ids:)
        root_by_conversation_id = root_ids.index_with(&:itself)
        account.conversations
          .where(canonical_conversation_id: root_ids)
          .pluck(:id, :canonical_conversation_id)
          .each do |conversation_id, root_id|
            root_by_conversation_id[conversation_id] = root_id
          end
        Conversations::ReviewWorkUnit.expand_root_mapping(
          account:,
          root_by_conversation_id:
        )
      end

      def latest_messages_by_root(
        account:,
        root_by_conversation_id:,
        direction: nil
      )
        connection = ConversationMessage.connection
        root_case = root_by_conversation_id.map do |conversation_id, root_id|
          "WHEN #{Integer(conversation_id)} THEN #{Integer(root_id)}"
        end.join(" ")
        root_sql = "CASE conversation_messages.conversation_id #{root_case} END"
        scope = account.conversation_messages
          .where(conversation_id: root_by_conversation_id.keys)
        scope = scope.where(direction:) if direction
        ranked = scope.select(
          "conversation_messages.id",
          "#{root_sql} AS inbox_root_id",
          "ROW_NUMBER() OVER (" \
            "PARTITION BY #{root_sql} " \
            "ORDER BY COALESCE(received_at, sent_at, created_at) DESC, id DESC" \
            ") AS inbox_row_number"
        )
        rows = connection.select_rows(
          "SELECT inbox_root_id, id FROM (#{ranked.to_sql}) AS ranked_messages " \
            "WHERE inbox_row_number = 1"
        )
        message_ids_by_root = rows.to_h.transform_keys(&:to_i).transform_values(&:to_i)
        messages_by_id = account.conversation_messages
          .where(id: message_ids_by_root.values)
          .index_by(&:id)
        message_ids_by_root.transform_values { |id| messages_by_id.fetch(id) }
      end

      def latest_workflow_item(actions:, escalations:, holds:)
        items = [
          *Array(actions).map do |action|
            {
              occurred_at: action.updated_at,
              summary: action.current_revision.user_facing_summary
            }
          end,
          *Array(escalations).map do |escalation|
            {
              occurred_at: escalation.updated_at,
              summary: escalation.summary
            }
          end,
          *Array(holds).map do |hold|
            {
              occurred_at: hold.updated_at,
              summary: "#{hold.reason.humanize} collection hold"
            }
          end
        ]
        items.max_by { |item| item.fetch(:occurred_at) }
      end
  end

  def initialize(account:, filter:)
    @account = account
    @filter = filter.to_s
    raise ArgumentError, "unsupported Inbox filter" unless FILTERS.include?(@filter)
  end

  def relation
    scoped = account.conversations
      .where(canonical_conversation_id: nil)
      .where(visible_review_owner_sql)
    scoped = scoped.where(message_exists_sql).or(
      scoped.where(workflow_exists_sql)
    )
    scoped = scoped
      .select(
        "conversations.*",
        "(#{latest_message_at_sql}) AS inbox_latest_message_at",
        "(#{latest_message_id_sql}) AS inbox_latest_message_id"
      )
      .includes(:customer, :invoice)

    if filter == "needs_attention"
      scoped = scoped.where.not(attention_required_at: nil)
        .or(scoped.where(review_exists_sql))
    end
    scoped = scoped.where(review_exists_sql) if filter == "needs_review"
    scoped.order(
      Arel.sql("inbox_latest_message_at DESC"),
      Arel.sql("inbox_latest_message_id DESC"),
      id: :desc
    )
  end

  private
    attr_reader :account, :filter

    def group_membership_sql
      Conversations::ReviewWorkUnit.group_membership_sql(
        message_alias: "inbox_messages",
        conversation_alias: "conversations"
      )
    end

    def message_exists_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1
          FROM conversation_messages AS inbox_messages
          WHERE #{group_membership_sql}
        )
      SQL
    end

    def review_exists_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1
          FROM conversation_messages AS inbox_messages
          WHERE (#{group_membership_sql})
            AND inbox_messages.email_connection_id IS NOT NULL
            AND inbox_messages.review_required = TRUE
            AND inbox_messages.reviewed_at IS NULL
        )
      SQL
    end

    def workflow_exists_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM conversation_actions
          WHERE conversation_actions.conversation_id = conversations.id
        )
        OR EXISTS (
          SELECT 1 FROM collection_holds
          WHERE collection_holds.conversation_id = conversations.id
        )
        OR EXISTS (
          SELECT 1 FROM conversation_escalations
          WHERE conversation_escalations.conversation_id = conversations.id
        )
      SQL
    end

    def visible_review_owner_sql
      Conversations::ReviewWorkUnit.visible_owner_sql(
        conversation_alias: "conversations"
      )
    end

    def latest_message_at_sql
      <<~SQL.squish
        GREATEST(
          COALESCE((
            SELECT MAX(
              COALESCE(
                inbox_messages.received_at,
                inbox_messages.sent_at,
                inbox_messages.created_at
              )
            )
            FROM conversation_messages AS inbox_messages
            WHERE #{group_membership_sql}
          ), '1970-01-01'),
          COALESCE((
            SELECT MAX(updated_at) FROM conversation_actions
            WHERE conversation_actions.conversation_id = conversations.id
          ), '1970-01-01'),
          COALESCE((
            SELECT MAX(updated_at) FROM collection_holds
            WHERE collection_holds.conversation_id = conversations.id
          ), '1970-01-01'),
          COALESCE((
            SELECT MAX(updated_at) FROM conversation_escalations
            WHERE conversation_escalations.conversation_id = conversations.id
          ), '1970-01-01')
        )
      SQL
    end

    def latest_message_id_sql
      <<~SQL.squish
        SELECT MAX(inbox_messages.id)
        FROM conversation_messages AS inbox_messages
        WHERE #{group_membership_sql}
      SQL
    end
end

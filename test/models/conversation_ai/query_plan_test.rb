require "test_helper"

class ConversationAi::QueryPlanTest < ActiveSupport::TestCase
  test "recurring lifecycle scopes expose their query-aligned indexes" do
    assert_possible_index(
      <<~SQL.squish,
        SELECT id
        FROM conversation_interpretations
        WHERE scheduling_status = 'reserved'
          AND (next_scheduling_at IS NULL OR next_scheduling_at <= NOW())
        ORDER BY id
        LIMIT 100
      SQL
      "index_interpretations_on_due_scheduling"
    )
    assert_possible_index(
      <<~SQL.squish,
        SELECT id
        FROM conversation_interpretations
        WHERE scheduling_status = 'claimed'
          AND scheduling_claimed_at < NOW()
        ORDER BY id
        LIMIT 100
      SQL
      "index_interpretations_on_stale_scheduling"
    )
    assert_possible_index(
      <<~SQL.squish,
        SELECT id
        FROM conversation_interpretations
        WHERE status = 'running'
          AND claimed_at < NOW()
        ORDER BY id
        LIMIT 100
      SQL
      "index_interpretations_on_stale_claims"
    )
    assert_possible_index(
      <<~SQL.squish,
        SELECT id
        FROM conversation_interpretations
        WHERE status = 'pending'
          AND next_retry_at <= NOW()
        ORDER BY id
        LIMIT 100
      SQL
      "index_interpretations_on_due_retry"
    )
  end

  test "account health current history guidance and report scopes expose indexes" do
    account_id = accounts(:paid_jar).id
    source_message_id = 1
    customer = customers(:xero_customer)
    CustomerAiProfile.create!(account: customer.account, customer:)
    customer_id = customer.id

    assert_possible_index(
      <<~SQL.squish,
        SELECT id
        FROM conversation_interpretations
        WHERE account_id = #{account_id}
          AND status = 'succeeded'
        ORDER BY completed_at DESC
        LIMIT 1
      SQL
      "index_interpretations_on_account_status"
    )
    assert_possible_index(
      <<~SQL.squish,
        SELECT id
        FROM conversation_interpretations
        WHERE account_id = #{account_id}
          AND source_message_id = #{source_message_id}
        ORDER BY created_at DESC
        LIMIT 1
      SQL
      "index_interpretations_on_source_history"
    )
    assert_possible_index(
      <<~SQL.squish,
        SELECT active_guidance_revision_id
        FROM customer_ai_profiles
        WHERE account_id = #{account_id}
          AND customer_id = #{customer_id}
        LIMIT 1
      SQL
      "index_customer_ai_profiles_on_account_customer"
    )
    assert_possible_index(
      <<~SQL.squish,
        SELECT provider, requested_model, semantic_prompt_version, COUNT(*)
        FROM conversation_interpretations
        WHERE account_id = #{account_id}
        GROUP BY provider, requested_model, semantic_prompt_version
      SQL
      "index_interpretations_on_report_versions"
    )
  end

  private
    def assert_possible_index(sql, index_name)
      plans = ApplicationRecord.connection.select_all("EXPLAIN #{sql}")
      possible_indexes = plans.flat_map do |plan|
        plan.fetch("possible_keys", "").to_s.split(",")
      end

      assert_includes possible_indexes, index_name, plans.to_a.inspect
    end
end

class ConversationAi::Report
  attr_reader :account

  def initialize(account:)
    @account = account
  end

  def totals
    statuses = interpretations.group(:status).count
    {
      "eligible" => interpretations.count,
      "successful" => statuses.fetch("succeeded", 0),
      "failed" => statuses.fetch("failed", 0),
      "skipped" => statuses.fetch("skipped", 0)
    }
  end

  def intent_distribution
    sql = ApplicationRecord.sanitize_sql_array(
      [
        <<~SQL.squish,
          SELECT intent_rows.intent_type, COUNT(*) AS result_count
          FROM conversation_interpretations
          JOIN JSON_TABLE(
            conversation_interpretations.structured_result,
            '$.intents[*]' COLUMNS(
              intent_type VARCHAR(64) PATH '$.type'
            )
          ) AS intent_rows
          WHERE conversation_interpretations.account_id = ?
            AND conversation_interpretations.status = 'succeeded'
          GROUP BY intent_rows.intent_type
        SQL
        account.id
      ]
    )
    ApplicationRecord.connection.select_rows(sql).to_h do |intent, count|
      [ intent, count.to_i ]
    end
  end

  def plan_distribution
    account.conversation_ai_plans.status_current.group(:decision).count
  end

  def evaluation_distribution
    latest = account.conversation_ai_evaluations.latest
    reviewed = latest.group(:verdict).count
    reviewed["unreviewed"] = interpretations
      .where(status: %i[succeeded skipped])
      .where.not(
        id: latest.select(:conversation_interpretation_id)
      )
      .count
    reviewed
  end

  def accuracy
    counts = evaluation_distribution
    denominator = counts.fetch("correct", 0) + counts.fetch("incorrect", 0)
    return nil if denominator.zero?

    (counts.fetch("correct", 0) * 100.0 / denominator).round(1)
  end

  def signal_distribution
    account.customer_ai_signals.group(:status).count
  end

  def version_breakdown
    interpretations
      .group(
        :provider,
        :requested_model,
        :accepted_model,
        :semantic_prompt_version,
        :provider_adapter_version,
        :result_schema_version,
        :planner_version
      )
      .count
  end

  private
    def interpretations
      account.conversation_interpretations
    end
end

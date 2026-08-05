defmodule ClusterMurmur.Repo.Migrations.CreateEntityStates do
  use Ecto.Migration

  @max_encoded_payload_bytes 128 * 1_024
  @max_safe_integer 9_007_199_254_740_991

  def change do
    create table(:entity_states, primary_key: false) do
      add :source, :text,
        primary_key: true,
        null: false,
        check: required_text("source")

      add :subject, :text,
        primary_key: true,
        null: false,
        check: required_text("subject")

      add :current_state, :text,
        null: false,
        check: %{
          name: "entity_states_current_state",
          expr: "\"current_state\" IN ('unknown', 'healthy', 'unhealthy')"
        }

      add :pending_state, :text,
        check: %{name: "entity_states_pending_progress", expr: pending_progress()}

      add :consecutive_count, :integer, null: false

      add :last_observed_at, :utc_datetime_usec,
        null: false,
        check: %{
          name: "entity_states_last_observed_at",
          expr: canonical_datetime("last_observed_at")
        }

      add :last_changed_at, :utc_datetime_usec,
        check: %{name: "entity_states_last_changed_at", expr: changed_time()}

      add :facts, :text, null: false, check: required_object("facts")

      add :labels, :text,
        null: false,
        check: %{
          name: "entity_states_payload",
          expr: required_object_expression("labels") <> " AND " <> payload_size_expression()
        }
    end
  end

  defp pending_progress do
    """
    COALESCE(
      (
        "current_state" = 'unknown' AND
        "pending_state" IS NOT NULL AND
        "pending_state" IN ('healthy', 'unhealthy') AND
        typeof("consecutive_count") = 'integer' AND
        "consecutive_count" BETWEEN 1 AND #{@max_safe_integer}
      ) OR (
        "current_state" IN ('healthy', 'unhealthy') AND
        (
          ("pending_state" IS NULL AND "consecutive_count" = 0) OR
          (
            "pending_state" IS NOT NULL AND
            "pending_state" IN ('healthy', 'unhealthy') AND
            "pending_state" <> "current_state" AND
            typeof("consecutive_count") = 'integer' AND
            "consecutive_count" BETWEEN 1 AND #{@max_safe_integer}
          )
        )
      ),
      0
    )
    """
  end

  defp changed_time do
    """
    (
      "current_state" = 'unknown' AND "last_changed_at" IS NULL
    ) OR (
      "current_state" IN ('healthy', 'unhealthy') AND
      #{canonical_datetime("last_changed_at")} AND
      "last_changed_at" <= "last_observed_at"
    )
    """
  end

  defp required_text(column),
    do: %{name: "entity_states_#{column}", expr: required_text_expression(column)}

  defp required_text_expression(column) do
    column = column_ref(column)

    """
    typeof(#{column}) = 'text' AND
    length(CAST(#{column} AS BLOB)) BETWEEN 1 AND 16384 AND
    instr(#{column}, char(0)) = 0
    """
  end

  defp required_object(column),
    do: %{name: "entity_states_#{column}", expr: required_object_expression(column)}

  defp required_object_expression(column) do
    column = column_ref(column)
    "typeof(#{column}) = 'text' AND json_valid(#{column}) AND json_type(#{column}) = 'object'"
  end

  defp payload_size_expression do
    """
    (length(CAST("facts" AS BLOB)) + length(CAST("labels" AS BLOB))) <=
    #{@max_encoded_payload_bytes}
    """
  end

  defp canonical_datetime(column) do
    column = column_ref(column)

    """
    typeof(#{column}) = 'text' AND
    length(CAST(#{column} AS BLOB)) = 27 AND
    instr(#{column}, char(0)) = 0 AND
    #{column} GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9]Z' AND
    datetime(#{column}, '+0 seconds') IS NOT NULL AND
    datetime(#{column}, '+0 seconds') = replace(substr(#{column}, 1, 19), 'T', ' ')
    """
  end

  defp column_ref(column), do: ~s("#{column}")
end

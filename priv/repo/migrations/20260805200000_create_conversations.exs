defmodule ClusterMurmur.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  @max_safe_integer 9_007_199_254_740_991

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :text,
        primary_key: true,
        null: false,
        check: %{name: "conversations_id", expr: portable_id("id")}

      add :root_event_id, references(:events, column: :id, type: :text),
        null: false,
        check: %{name: "conversations_root_event_id", expr: required_text("root_event_id")}

      add :status, :text,
        null: false,
        check: %{
          name: "conversations_status",
          expr:
            "status IN ('starting', 'generating', 'waiting', 'completed', 'cancelled', 'failed')"
        }

      add :turn_count, :integer,
        null: false,
        check: %{name: "conversations_turn_count", expr: safe_counter("turn_count")}

      add :llm_call_count, :integer,
        null: false,
        check: %{name: "conversations_llm_call_count", expr: safe_counter("llm_call_count")}

      add :started_at, :utc_datetime_usec,
        null: false,
        check: %{name: "conversations_started_at", expr: canonical_datetime("started_at")}

      add :completed_at, :utc_datetime_usec,
        check: %{name: "conversations_completed_at", expr: completed_at_for_status()}
    end

    create index(:conversations, [:root_event_id])
    create index(:conversations, [:status, :started_at])
  end

  defp portable_id(column) do
    column_ref = column_ref(column)

    """
    #{required_text(column)} AND
    #{column_ref} NOT GLOB '*[^A-Za-z0-9._-]*' AND
    substr(#{column_ref}, 1, 1) GLOB '[A-Za-z0-9]'
    """
  end

  defp required_text(column) do
    column = column_ref(column)

    """
    typeof(#{column}) = 'text' AND
    length(CAST(#{column} AS BLOB)) BETWEEN 1 AND 16384 AND
    instr(#{column}, char(0)) = 0
    """
  end

  defp safe_counter(column) do
    column = column_ref(column)

    "typeof(#{column}) = 'integer' AND #{column} BETWEEN 0 AND #{@max_safe_integer}"
  end

  defp completed_at_for_status do
    completed_at = column_ref("completed_at")

    """
    (
      status IN ('starting', 'generating', 'waiting') AND
      #{completed_at} IS NULL
    ) OR (
      status IN ('completed', 'cancelled', 'failed') AND
      #{canonical_datetime("completed_at")} AND
      #{completed_at} >= started_at
    )
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

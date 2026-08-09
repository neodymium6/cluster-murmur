defmodule ClusterMurmur.Repo.Migrations.CreateEventRetentionSweeps do
  use Ecto.Migration

  def change do
    create table(:event_retention_sweeps, primary_key: false) do
      add :scope, :text,
        primary_key: true,
        null: false,
        check: %{name: "event_retention_sweeps_scope", expr: "scope = 'events'"}

      add :cursor_occurred_at, :utc_datetime_usec,
        check: %{
          name: "event_retention_sweeps_cursor_occurred_at",
          expr: optional_datetime("cursor_occurred_at")
        }

      add :cursor_event_id, :text,
        check: %{
          name: "event_retention_sweeps_cursor_pair",
          expr: optional_text("cursor_event_id") <> " AND " <> cursor_pair()
        }

      add :swept_at, :utc_datetime_usec,
        null: false,
        check: %{
          name: "event_retention_sweeps_swept_at",
          expr: canonical_datetime("swept_at")
        }
    end
  end

  defp cursor_pair do
    "((cursor_occurred_at IS NULL AND cursor_event_id IS NULL) OR " <>
      "(cursor_occurred_at IS NOT NULL AND cursor_event_id IS NOT NULL))"
  end

  defp optional_text(column) do
    column = column_ref(column)

    "(#{column} IS NULL OR (" <>
      "typeof(#{column}) = 'text' AND " <>
      "length(CAST(#{column} AS BLOB)) BETWEEN 1 AND 16384 AND " <>
      "instr(#{column}, char(0)) = 0))"
  end

  defp optional_datetime(column) do
    column_ref = column_ref(column)
    "#{column_ref} IS NULL OR (#{canonical_datetime(column)})"
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

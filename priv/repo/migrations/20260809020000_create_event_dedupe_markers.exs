defmodule ClusterMurmur.Repo.Migrations.CreateEventDedupeMarkers do
  use Ecto.Migration

  def change do
    create table(:event_dedupe_markers, primary_key: false) do
      add :dedupe_key, :text,
        primary_key: true,
        null: false,
        check: %{name: "event_dedupe_markers_dedupe_key", expr: required_text("dedupe_key")}

      add :event_id, references(:events, column: :id, type: :text),
        null: false,
        check: %{name: "event_dedupe_markers_event_id", expr: required_text("event_id")}

      add :accepted_at, :utc_datetime_usec,
        null: false,
        check: %{
          name: "event_dedupe_markers_accepted_at",
          expr: canonical_datetime("accepted_at")
        }
    end

    create index(:event_dedupe_markers, [:accepted_at])
  end

  defp required_text(column) do
    column = column_ref(column)

    """
    typeof(#{column}) = 'text' AND
    length(CAST(#{column} AS BLOB)) BETWEEN 1 AND 16384 AND
    instr(#{column}, char(0)) = 0
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

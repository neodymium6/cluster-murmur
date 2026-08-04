defmodule ClusterMurmur.Repo.Migrations.CreateTriggerExecutions do
  use Ecto.Migration

  def change do
    create table(:trigger_executions, primary_key: false) do
      add :trigger_id, :text,
        primary_key: true,
        null: false,
        check: %{
          name: "trigger_executions_trigger_id",
          expr: portable_id("trigger_id")
        }

      add :event_id, references(:events, column: :id, type: :text),
        primary_key: true,
        null: false,
        check: %{
          name: "trigger_executions_event_id",
          expr: required_text("event_id")
        }

      add :status, :text,
        null: false,
        check: %{
          name: "trigger_executions_status",
          expr: "status IN ('started', 'completed', 'failed')"
        }

      add :executed_at, :utc_datetime_usec,
        null: false,
        check: %{
          name: "trigger_executions_executed_at",
          expr: canonical_datetime("executed_at")
        }

      add :cooldown_until, :utc_datetime_usec,
        null: false,
        check: %{
          name: "trigger_executions_cooldown_until",
          expr:
            canonical_datetime("cooldown_until") <>
              " AND cooldown_until >= executed_at"
        }

      add :error_class, :text,
        check: %{
          name: "trigger_executions_error_class",
          expr: error_class_for_status()
        }
    end

    create index(:trigger_executions, [:cooldown_until])
    create index(:trigger_executions, [:executed_at])
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

  defp error_class_for_status do
    """
    (status IN ('started', 'completed') AND error_class IS NULL) OR
    (
      status = 'failed' AND
      typeof(error_class) = 'text' AND
      length(CAST(error_class AS BLOB)) BETWEEN 1 AND 128 AND
      instr(error_class, char(0)) = 0 AND
      error_class NOT GLOB '*[^a-z0-9._-]*' AND
      substr(error_class, 1, 1) GLOB '[a-z]'
    )
    """
  end

  defp column_ref(column), do: ~s("#{column}")
end

defmodule ClusterMurmur.Repo.Migrations.CreateStochasticSchedules do
  use Ecto.Migration

  def change do
    create table(:stochastic_schedules, primary_key: false) do
      add :trigger_id, :text,
        primary_key: true,
        null: false,
        check: %{
          name: "stochastic_schedules_trigger_id",
          expr: """
          typeof(trigger_id) = 'text' AND
          length(CAST(trigger_id AS BLOB)) BETWEEN 1 AND 16384 AND
          instr(trigger_id, char(0)) = 0 AND
          trigger_id NOT GLOB '*[^A-Za-z0-9._-]*' AND
          substr(trigger_id, 1, 1) GLOB '[A-Za-z0-9]'
          """
        }

      add :next_run_at, :utc_datetime_usec,
        null: false,
        check: %{
          name: "stochastic_schedules_next_run_at",
          expr: canonical_datetime("next_run_at")
        }

      add :last_run_at, :utc_datetime_usec,
        check: %{
          name: "stochastic_schedules_run_order",
          expr:
            "last_run_at IS NULL OR " <>
              "(#{canonical_datetime("last_run_at")} AND next_run_at > last_run_at)"
        }

      add :daily_count, :integer,
        null: false,
        default: 0,
        check: %{
          name: "stochastic_schedules_daily_count_bounds",
          expr: "typeof(daily_count) = 'integer' AND daily_count >= 0 AND daily_count <= 10000"
        }

      add :daily_count_date, :date,
        check: %{
          name: "stochastic_schedules_daily_bucket",
          expr:
            "(daily_count_date IS NULL OR #{canonical_date("daily_count_date")}) AND " <>
              "(daily_count = 0 OR daily_count_date IS NOT NULL)"
        }
    end

    create index(:stochastic_schedules, [:next_run_at])
  end

  defp canonical_datetime(column) do
    """
    typeof(#{column}) = 'text' AND
    length(CAST(#{column} AS BLOB)) = 27 AND
    instr(#{column}, char(0)) = 0 AND
    #{column} GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9]Z' AND
    datetime(#{column}, '+0 seconds') IS NOT NULL AND
    datetime(#{column}, '+0 seconds') = replace(substr(#{column}, 1, 19), 'T', ' ')
    """
  end

  defp canonical_date(column) do
    """
    typeof(#{column}) = 'text' AND
    length(CAST(#{column} AS BLOB)) = 10 AND
    instr(#{column}, char(0)) = 0 AND
    #{column} GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND
    date(#{column}, '+0 days') IS NOT NULL AND
    date(#{column}, '+0 days') = #{column}
    """
  end
end

defmodule ClusterMurmur.Repo.Migrations.CreateScheduleStates do
  use Ecto.Migration

  def change do
    create table(:schedule_states, primary_key: false) do
      add :trigger_id, :text,
        primary_key: true,
        null: false,
        check: %{name: "schedule_states_trigger_id", expr: portable_id("trigger_id")}

      add :next_run_at, :utc_datetime_usec,
        null: false,
        check: %{name: "schedule_states_next_run_at", expr: canonical_datetime("next_run_at")}

      add :last_run_at, :utc_datetime_usec,
        check: %{
          name: "schedule_states_run_order",
          expr:
            "last_run_at IS NULL OR " <>
              "(#{canonical_datetime("last_run_at")} AND next_run_at > last_run_at)"
        }

      add :claim_token, :text,
        check: %{name: "schedule_states_claim_token", expr: optional_claim_token()}

      add :claim_started_at, :utc_datetime_usec,
        check: %{
          name: "schedule_states_claim_started_at",
          expr: "claim_started_at IS NULL OR #{canonical_datetime("claim_started_at")}"
        }

      add :claim_expires_at, :utc_datetime_usec,
        check: %{name: "schedule_states_claim_pair", expr: claim_pair()}
    end

    create index(:schedule_states, [:next_run_at, :trigger_id])
    create index(:schedule_states, [:claim_expires_at])
  end

  defp portable_id(column) do
    """
    typeof(#{column}) = 'text' AND
    length(CAST(#{column} AS BLOB)) BETWEEN 1 AND 16384 AND
    instr(#{column}, char(0)) = 0 AND
    #{column} NOT GLOB '*[^A-Za-z0-9._-]*' AND
    substr(#{column}, 1, 1) GLOB '[A-Za-z0-9]'
    """
  end

  defp optional_claim_token do
    """
    claim_token IS NULL OR (
      typeof(claim_token) = 'text' AND
      length(CAST(claim_token AS BLOB)) = 43 AND
      instr(claim_token, char(0)) = 0 AND
      claim_token NOT GLOB '*[^A-Za-z0-9_-]*'
    )
    """
  end

  defp claim_pair do
    """
    (claim_token IS NULL AND claim_started_at IS NULL AND claim_expires_at IS NULL) OR
    (
      claim_token IS NOT NULL AND
      #{canonical_datetime("claim_started_at")} AND
      #{canonical_datetime("claim_expires_at")} AND
      claim_expires_at > claim_started_at
    )
    """
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
end

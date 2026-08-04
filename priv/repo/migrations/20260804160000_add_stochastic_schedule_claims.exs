defmodule ClusterMurmur.Repo.Migrations.AddStochasticScheduleClaims do
  use Ecto.Migration

  def change do
    alter table(:stochastic_schedules) do
      add :claim_token, :text,
        check: %{
          name: "stochastic_schedules_claim_token",
          expr: """
          claim_token IS NULL OR (
            typeof(claim_token) = 'text' AND
            length(CAST(claim_token AS BLOB)) = 43 AND
            instr(claim_token, char(0)) = 0 AND
            claim_token NOT GLOB '*[^A-Za-z0-9_-]*'
          )
          """
        }

      add :claim_started_at, :utc_datetime_usec,
        check: %{
          name: "stochastic_schedules_claim_started_at",
          expr: "claim_started_at IS NULL OR #{canonical_datetime("claim_started_at")}"
        }

      add :claim_expires_at, :utc_datetime_usec,
        check: %{
          name: "stochastic_schedules_claim_pair",
          expr: """
          (claim_token IS NULL AND claim_started_at IS NULL AND claim_expires_at IS NULL) OR
          (
            claim_token IS NOT NULL AND
            #{canonical_datetime("claim_started_at")} AND
            #{canonical_datetime("claim_expires_at")} AND
            claim_expires_at > claim_started_at
          )
          """
        }
    end
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

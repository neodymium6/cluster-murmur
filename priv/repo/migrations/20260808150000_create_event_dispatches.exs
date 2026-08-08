defmodule ClusterMurmur.Repo.Migrations.CreateEventDispatches do
  use Ecto.Migration

  def change do
    create table(:event_dispatches, primary_key: false) do
      add :event_id, references(:events, column: :id, type: :text),
        primary_key: true,
        null: false,
        check: %{name: "event_dispatches_event_id", expr: required_text("event_id")}

      add :status, :text,
        null: false,
        check: %{name: "event_dispatches_status", expr: lifecycle()}

      add :enqueued_at, :utc_datetime_usec,
        null: false,
        check: %{
          name: "event_dispatches_enqueued_at",
          expr: canonical_datetime("enqueued_at")
        }

      add :claim_token, :text,
        check: %{name: "event_dispatches_claim_token", expr: optional_claim_token()}

      add :claim_started_at, :utc_datetime_usec,
        check: %{
          name: "event_dispatches_claim_started_at",
          expr: optional_time("claim_started_at")
        }

      add :claim_expires_at, :utc_datetime_usec,
        check: %{name: "event_dispatches_claim_expires_at", expr: claim_expiry()}

      add :completed_at, :utc_datetime_usec,
        check: %{name: "event_dispatches_completed_at", expr: completed_time()}
    end

    create index(:event_dispatches, [:status, :enqueued_at, :event_id])
    create index(:event_dispatches, [:claim_expires_at])
  end

  defp lifecycle do
    """
    COALESCE(
      (
        status = 'pending' AND claim_token IS NULL AND
        claim_started_at IS NULL AND claim_expires_at IS NULL AND completed_at IS NULL
      ) OR
      (
        status = 'claimed' AND claim_token IS NOT NULL AND
        claim_started_at IS NOT NULL AND claim_started_at >= enqueued_at AND
        claim_expires_at IS NOT NULL AND completed_at IS NULL
      ) OR
      (
        status = 'completed' AND claim_token IS NULL AND
        claim_started_at IS NULL AND claim_expires_at IS NULL AND completed_at IS NOT NULL
      ),
      0
    )
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

  defp optional_time(column) do
    column_ref = column_ref(column)
    "#{column_ref} IS NULL OR (#{canonical_datetime(column)})"
  end

  defp claim_expiry do
    """
    claim_expires_at IS NULL OR (
      #{canonical_datetime("claim_expires_at")} AND
      claim_started_at IS NOT NULL AND claim_expires_at > claim_started_at
    )
    """
  end

  defp completed_time do
    """
    completed_at IS NULL OR (
      #{canonical_datetime("completed_at")} AND completed_at >= enqueued_at
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

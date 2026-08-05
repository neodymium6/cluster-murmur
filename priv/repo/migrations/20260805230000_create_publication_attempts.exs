defmodule ClusterMurmur.Repo.Migrations.CreatePublicationAttempts do
  use Ecto.Migration

  def change do
    create table(:publication_attempts, primary_key: false) do
      add :message_id, references(:messages, type: :integer), null: false

      add :status, :text,
        null: false,
        check: %{name: "publication_attempts_status", expr: lifecycle()}

      add :started_at, :utc_datetime_usec,
        null: false,
        check: %{
          name: "publication_attempts_started_at",
          expr: canonical_datetime("started_at")
        }

      add :completed_at, :utc_datetime_usec,
        check: %{
          name: "publication_attempts_completed_at",
          expr: completed_time()
        }

      add :error_class, :text,
        check: %{name: "publication_attempts_error_class", expr: error_class()}
    end

    create unique_index(:publication_attempts, [:message_id])
  end

  defp lifecycle do
    """
    COALESCE(
      (status = 'started' AND completed_at IS NULL AND error_class IS NULL) OR
      (status = 'succeeded' AND completed_at IS NOT NULL AND error_class IS NULL) OR
      (
        status = 'failed' AND completed_at IS NOT NULL AND error_class IN (
          'authentication_failed', 'invalid_request', 'invalid_response',
          'rate_limited', 'timeout', 'unavailable'
        )
      ) OR
      (status = 'ambiguous' AND completed_at IS NOT NULL AND error_class = 'interrupted'),
      0
    )
    """
  end

  defp completed_time do
    """
    completed_at IS NULL OR (
      #{canonical_datetime("completed_at")} AND completed_at >= started_at
    )
    """
  end

  defp error_class do
    """
    error_class IS NULL OR error_class IN (
      'authentication_failed', 'invalid_request', 'invalid_response',
      'rate_limited', 'timeout', 'unavailable', 'interrupted'
    )
    """
  end

  defp canonical_datetime(column) do
    column = ~s("#{column}")

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

defmodule ClusterMurmur.Repo.Migrations.AddPublicationAttemptDispatching do
  use Ecto.Migration

  def up do
    rebuild(
      lifecycle_with_dispatching(),
      "message_id, status, started_at, completed_at, error_class"
    )
  end

  def down do
    projection = """
    message_id,
    CASE status WHEN 'dispatching' THEN 'ambiguous' ELSE status END,
    started_at,
    CASE status WHEN 'dispatching' THEN started_at ELSE completed_at END,
    CASE status WHEN 'dispatching' THEN 'interrupted' ELSE error_class END
    """

    rebuild(original_lifecycle(), projection)
  end

  defp rebuild(lifecycle, projection) do
    execute("""
    CREATE TABLE publication_attempts_rebuilt (
      message_id INTEGER NOT NULL REFERENCES messages(id),
      status TEXT NOT NULL CONSTRAINT publication_attempts_status CHECK (#{lifecycle}),
      started_at TEXT NOT NULL CONSTRAINT publication_attempts_started_at CHECK (
        #{canonical_datetime("started_at")}
      ),
      completed_at TEXT CONSTRAINT publication_attempts_completed_at CHECK (
        completed_at IS NULL OR (
          #{canonical_datetime("completed_at")} AND completed_at >= started_at
        )
      ),
      error_class TEXT CONSTRAINT publication_attempts_error_class CHECK (
        error_class IS NULL OR error_class IN (
          'authentication_failed', 'invalid_request', 'invalid_response',
          'rate_limited', 'timeout', 'unavailable', 'interrupted'
        )
      )
    )
    """)

    execute("""
    INSERT INTO publication_attempts_rebuilt
      (message_id, status, started_at, completed_at, error_class)
    SELECT #{projection}
    FROM publication_attempts
    """)

    execute("DROP TABLE publication_attempts")
    execute("ALTER TABLE publication_attempts_rebuilt RENAME TO publication_attempts")

    execute("""
    CREATE UNIQUE INDEX publication_attempts_message_id_index
    ON publication_attempts (message_id)
    """)
  end

  defp lifecycle_with_dispatching do
    """
    COALESCE(
      (status IN ('started', 'dispatching') AND completed_at IS NULL AND error_class IS NULL) OR
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

  defp original_lifecycle do
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

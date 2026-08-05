defmodule ClusterMurmur.Repo.Migrations.CreatePersonaCooldowns do
  use Ecto.Migration

  def change do
    create table(:persona_cooldowns, primary_key: false) do
      add :persona_id, :text,
        primary_key: true,
        null: false,
        check: %{name: "persona_cooldowns_persona_id", expr: portable_id("persona_id")}

      add :cooldown_until, :utc_datetime_usec,
        null: false,
        check: %{name: "persona_cooldowns_cooldown_until", expr: cooldown_deadline()}

      add :last_spoken_at, :utc_datetime_usec,
        null: false,
        check: %{
          name: "persona_cooldowns_last_spoken_at",
          expr: canonical_datetime("last_spoken_at")
        }
    end
  end

  defp portable_id(column) do
    column = column_ref(column)

    """
    typeof(#{column}) = 'text' AND
    length(CAST(#{column} AS BLOB)) BETWEEN 1 AND 16384 AND
    instr(#{column}, char(0)) = 0 AND
    #{column} NOT GLOB '*[^A-Za-z0-9._-]*' AND
    substr(#{column}, 1, 1) GLOB '[A-Za-z0-9]'
    """
  end

  defp cooldown_deadline do
    cooldown_until = column_ref("cooldown_until")
    last_spoken_at = column_ref("last_spoken_at")

    """
    #{canonical_datetime("cooldown_until")} AND
    #{cooldown_until} >= #{last_spoken_at} AND
    (
      unixepoch(#{cooldown_until}) - unixepoch(#{last_spoken_at}) < 31536000 OR
      (
        unixepoch(#{cooldown_until}) - unixepoch(#{last_spoken_at}) = 31536000 AND
        substr(#{cooldown_until}, 20, 7) <= substr(#{last_spoken_at}, 20, 7)
      )
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

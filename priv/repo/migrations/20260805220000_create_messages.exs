defmodule ClusterMurmur.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  @max_content_bytes 16 * 1_024
  @max_snowflake "18446744073709551615"
  @blank_codepoints [
    0x0009,
    0x000A,
    0x000B,
    0x000C,
    0x000D,
    0x0020,
    0x0085,
    0x00A0,
    0x00AD,
    0x1680,
    0x180E,
    0x2000,
    0x2001,
    0x2002,
    0x2003,
    0x2004,
    0x2005,
    0x2006,
    0x2007,
    0x2008,
    0x2009,
    0x200A,
    0x200B,
    0x200C,
    0x200D,
    0x2028,
    0x2029,
    0x202F,
    0x205F,
    0x2060,
    0x3000,
    0xFEFF
  ]

  def change do
    create table(:messages) do
      add :conversation_id, references(:conversations, column: :id, type: :text),
        null: false,
        check: %{name: "messages_conversation_id", expr: portable_id("conversation_id")}

      add :persona_id, :text,
        null: false,
        check: %{name: "messages_persona_id", expr: portable_id("persona_id")}

      add :origin, :text,
        null: false,
        check: %{name: "messages_origin", expr: "origin IN ('llm', 'fallback')"}

      add :content, :text,
        null: false,
        check: %{name: "messages_content", expr: bounded_content()}

      add :discord_message_id, :text,
        check: %{name: "messages_discord_message_id", expr: optional_snowflake()}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        check: %{name: "messages_inserted_at", expr: canonical_datetime("inserted_at")}
    end

    create index(:messages, [:conversation_id, :inserted_at, :id])

    create unique_index(:messages, [:discord_message_id], where: "discord_message_id IS NOT NULL")
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

  defp bounded_content do
    content = column_ref("content")
    blank_characters = Enum.map_join(@blank_codepoints, " || ", &"char(#{&1})")

    """
    typeof(#{content}) = 'text' AND
    length(CAST(#{content} AS BLOB)) BETWEEN 1 AND #{@max_content_bytes} AND
    instr(#{content}, char(0)) = 0 AND
    length(trim(#{content}, #{blank_characters})) > 0
    """
  end

  defp optional_snowflake do
    discord_id = column_ref("discord_message_id")

    """
    #{discord_id} IS NULL OR (
      typeof(#{discord_id}) = 'text' AND
      length(CAST(#{discord_id} AS BLOB)) BETWEEN 1 AND 20 AND
      instr(#{discord_id}, char(0)) = 0 AND
      #{discord_id} NOT GLOB '*[^0-9]*' AND
      substr(#{discord_id}, 1, 1) GLOB '[1-9]' AND
      (
        length(CAST(#{discord_id} AS BLOB)) < 20 OR
        #{discord_id} <= '#{@max_snowflake}'
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

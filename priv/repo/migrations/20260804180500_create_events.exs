defmodule ClusterMurmur.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  @max_encoded_payload_bytes 512 * 1_024

  def change do
    create table(:events, primary_key: false) do
      add :id, :text, primary_key: true, null: false, check: required_text("id")
      add :type, :text, null: false, check: required_text("type")
      add :source, :text, null: false, check: required_text("source")
      add :subject, :text, check: optional_text("subject")
      add :group, :text, check: optional_text("group")
      add :severity, :text, check: optional_text("severity")
      add :previous, :text, check: optional_json("previous")
      add :current, :text, check: optional_json("current")
      add :dedupe_key, :text, check: optional_text("dedupe_key")
      add :correlation_key, :text, check: optional_text("correlation_key")
      add :facts, :text, null: false, check: required_object("facts")

      add :labels, :text,
        null: false,
        check: %{
          name: "events_payload",
          expr: required_object_expression("labels") <> " AND " <> payload_size_expression()
        }

      add :occurred_at, :utc_datetime_usec,
        null: false,
        check: %{name: "events_occurred_at", expr: canonical_datetime("occurred_at")}

      add :observed_at, :utc_datetime_usec,
        check: %{
          name: "events_observed_at",
          expr: "#{column_ref("observed_at")} IS NULL OR #{canonical_datetime("observed_at")}"
        }

      add :inserted_at, :utc_datetime_usec,
        null: false,
        check: %{name: "events_inserted_at", expr: canonical_datetime("inserted_at")}
    end

    create index(:events, [:occurred_at])
    create index(:events, [:dedupe_key])
  end

  defp required_text(column),
    do: %{name: "events_#{column}", expr: required_text_expression(column)}

  defp optional_text(column) do
    %{
      name: "events_#{column}",
      expr: "#{column_ref(column)} IS NULL OR (#{required_text_expression(column)})"
    }
  end

  defp required_text_expression(column) do
    column = column_ref(column)

    """
    typeof(#{column}) = 'text' AND
    length(CAST(#{column} AS BLOB)) BETWEEN 1 AND 16384 AND
    instr(#{column}, char(0)) = 0
    """
  end

  defp optional_json(column) do
    column_ref = column_ref(column)

    %{
      name: "events_#{column}",
      expr:
        "#{column_ref} IS NULL OR " <>
          "(typeof(#{column_ref}) = 'text' AND json_valid(#{column_ref}))"
    }
  end

  defp required_object(column),
    do: %{name: "events_#{column}", expr: required_object_expression(column)}

  defp required_object_expression(column) do
    column = column_ref(column)

    "typeof(#{column}) = 'text' AND json_valid(#{column}) AND json_type(#{column}) = 'object'"
  end

  defp payload_size_expression do
    columns = ["previous", "current", "facts", "labels"]

    total =
      columns
      |> Enum.map_join(" + ", fn column ->
        column = column_ref(column)
        "COALESCE(length(CAST(#{column} AS BLOB)), 0)"
      end)

    "(#{total}) <= #{@max_encoded_payload_bytes}"
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

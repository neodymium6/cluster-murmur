defmodule ClusterMurmur.Repo.Migrations.CreateResponderGenerationClaims do
  use Ecto.Migration

  def change do
    create table(:responder_generation_claims, primary_key: false) do
      add :conversation_id,
          references(:conversations, type: :string, on_delete: :delete_all),
          primary_key: true,
          null: false

      add :persona_id, :text,
        null: false,
        check: %{
          name: "responder_generation_claims_persona_id",
          expr: portable_id("persona_id")
        }

      add :turn_count, :integer,
        null: false,
        check: %{
          name: "responder_generation_claims_turn_count",
          expr: safe_counter("turn_count", 0)
        }

      add :llm_call_count, :integer,
        null: false,
        check: %{
          name: "responder_generation_claims_llm_call_count",
          expr: safe_counter("llm_call_count", 1)
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

  defp safe_counter(column, minimum) do
    column = column_ref(column)

    "typeof(#{column}) = 'integer' AND " <>
      "#{column} BETWEEN #{minimum} AND 9007199254740991"
  end

  defp column_ref(column), do: ~s("#{column}")
end

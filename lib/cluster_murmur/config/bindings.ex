defmodule ClusterMurmur.Config.Bindings do
  @moduledoc """
  Validates and combines version 1 binding documents.

  Group and persona IDs are normalized but remain unresolved until complete
  configuration assembly. Duplicate namespaces and candidate identities are
  rejected without exposing configuration values in errors or inspection.
  """

  alias ClusterMurmur.Config.{LoadedDocument, SchemaValidator, Value}
  alias ClusterMurmur.Personas.{Binding, BindingValidator}

  @draft "http://json-schema.org/draft-07/schema#"
  @id_pattern "^[A-Za-z0-9][A-Za-z0-9._-]*$"
  @max_bindings 256

  @schema %{
    "$schema" => @draft,
    "type" => "object",
    "required" => ["bindings"],
    "additionalProperties" => false,
    "properties" => %{
      "bindings" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["id", "match", "candidates"],
          "additionalProperties" => false,
          "properties" => %{
            "id" => %{"type" => "string", "pattern" => @id_pattern},
            "match" => %{
              "type" => "object",
              "required" => ["group"],
              "additionalProperties" => false,
              "properties" => %{
                "group" => %{"type" => "string", "pattern" => @id_pattern}
              }
            },
            "candidates" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => 256,
              "items" => %{
                "type" => "object",
                "required" => ["persona", "weight"],
                "additionalProperties" => false,
                "properties" => %{
                  "persona" => %{"type" => "string", "pattern" => @id_pattern},
                  "weight" => %{"type" => "number", "minimum" => 0}
                }
              }
            }
          }
        }
      }
    }
  }

  @derive {Inspect, only: []}
  @enforce_keys [:bindings]
  defstruct [:bindings]

  @type t :: %__MODULE__{bindings: %{required(String.t()) => Binding.t()}}
  @type error ::
          :duplicate_binding
          | :duplicate_binding_candidate
          | :invalid_binding_document
          | :invalid_binding_schema
          | :too_many_bindings

  @doc "Validates and combines decoded binding documents."
  @spec parse_documents(term()) :: {:ok, t()} | {:error, error()}
  def parse_documents(documents) when is_list(documents) do
    with {:ok, validator} <- compile_schema() do
      parse_document_list(documents, validator, %{}, 0)
    end
  end

  def parse_documents(_documents), do: {:error, :invalid_binding_document}

  defp compile_schema do
    case SchemaValidator.compile(@schema) do
      {:ok, validator} -> {:ok, validator}
      {:error, _reason} -> {:error, :invalid_binding_schema}
    end
  end

  defp parse_document_list([], _validator, bindings, _count),
    do: {:ok, %__MODULE__{bindings: bindings}}

  defp parse_document_list(
         [%LoadedDocument{document: document} | documents],
         validator,
         bindings,
         count
       ) do
    with :ok <- validate_document(validator, document),
         {:ok, bindings, count} <- collect_bindings(document["bindings"], bindings, count) do
      parse_document_list(documents, validator, bindings, count)
    end
  end

  defp parse_document_list(_documents, _validator, _bindings, _count),
    do: {:error, :invalid_binding_document}

  defp validate_document(validator, document) do
    case SchemaValidator.validate(validator, document) do
      :ok -> :ok
      {:error, :schema_violation} -> {:error, :invalid_binding_document}
      {:error, :invalid_schema_validator} -> {:error, :invalid_binding_schema}
    end
  end

  defp collect_bindings(document_bindings, bindings, count) do
    document_bindings
    |> Enum.sort_by(&Map.get(&1, "id"))
    |> Enum.reduce_while({:ok, bindings, count}, fn attributes, {:ok, bindings, count} ->
      collect_binding(attributes, bindings, count)
    end)
  end

  defp collect_binding(attributes, bindings, count) do
    id = attributes["id"]

    cond do
      Map.has_key?(bindings, id) ->
        {:halt, {:error, :duplicate_binding}}

      count >= @max_bindings ->
        {:halt, {:error, :too_many_bindings}}

      true ->
        case build_binding(attributes) do
          {:ok, binding} ->
            {:cont, {:ok, Map.put(bindings, binding.id, binding), count + 1}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end
  end

  defp build_binding(attributes) do
    with {:ok, id} <- validate_id(attributes["id"]),
         {:ok, group} <- validate_id(attributes["match"]["group"]),
         {:ok, candidates} <- validate_candidates(attributes["candidates"]) do
      binding = %Binding{id: id, group: group, candidates: candidates}

      if BindingValidator.validate(binding) == :ok,
        do: {:ok, binding},
        else: {:error, :invalid_binding_document}
    end
  end

  defp validate_id(value) do
    case Value.id(value) do
      {:ok, id} -> {:ok, id}
      {:error, _reason} -> {:error, :invalid_binding_document}
    end
  end

  defp validate_candidates(candidates) do
    candidates
    |> Enum.sort_by(&Map.get(&1, "persona"))
    |> Enum.reduce_while({:ok, [], MapSet.new()}, &validate_candidate/2)
    |> case do
      {:ok, validated, _seen} -> {:ok, Enum.reverse(validated)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_candidate(attributes, {:ok, candidates, seen}) do
    persona = attributes["persona"]

    if MapSet.member?(seen, persona) do
      {:halt, {:error, :duplicate_binding_candidate}}
    else
      with {:ok, persona} <- validate_id(persona),
           {:ok, weight} <- Value.weight(attributes["weight"]) do
        candidate = %{persona: persona, weight: weight}
        {:cont, {:ok, [candidate | candidates], MapSet.put(seen, persona)}}
      else
        {:error, _reason} -> {:halt, {:error, :invalid_binding_document}}
      end
    end
  end
end

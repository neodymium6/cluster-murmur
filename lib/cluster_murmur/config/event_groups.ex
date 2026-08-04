defmodule ClusterMurmur.Config.EventGroups do
  @moduledoc """
  Validates and combines version 1 event-group documents.

  Each document first passes the application-owned structural schema. Semantic
  validation then applies shared scalar rules, rejects duplicate IDs across
  files, and enforces one aggregate bound. Source paths and rejected values are
  not included in errors or normal inspection.
  """

  alias ClusterMurmur.Config.{LoadedDocument, SchemaValidator, Value}

  @draft "http://json-schema.org/draft-07/schema#"
  @max_groups 256
  @id_pattern "^[A-Za-z0-9][A-Za-z0-9._-]*$"

  @schema %{
    "$schema" => @draft,
    "type" => "object",
    "required" => ["event_groups"],
    "additionalProperties" => false,
    "properties" => %{
      "event_groups" => %{
        "type" => "object",
        "propertyNames" => %{"pattern" => @id_pattern},
        "additionalProperties" => %{
          "type" => "object",
          "required" => ["reply_probability"],
          "additionalProperties" => false,
          "properties" => %{
            "reply_probability" => %{
              "type" => "number",
              "minimum" => 0,
              "maximum" => 1
            }
          }
        }
      }
    }
  }

  @derive {Inspect, only: []}
  @enforce_keys [:groups]
  defstruct [:groups]

  @type group :: %{required(:id) => String.t(), required(:reply_probability) => number()}
  @type t :: %__MODULE__{groups: %{required(String.t()) => group()}}

  @type error ::
          :duplicate_event_group
          | :invalid_event_group_document
          | :invalid_event_group_schema
          | :too_many_event_groups

  @doc "Validates and combines decoded event-group documents."
  @spec parse_documents(term()) :: {:ok, t()} | {:error, error()}
  def parse_documents(documents) when is_list(documents) do
    with {:ok, validator} <- compile_schema() do
      parse_document_list(documents, validator, %{}, 0)
    end
  end

  def parse_documents(_documents), do: {:error, :invalid_event_group_document}

  defp compile_schema do
    case SchemaValidator.compile(@schema) do
      {:ok, validator} -> {:ok, validator}
      {:error, _reason} -> {:error, :invalid_event_group_schema}
    end
  end

  defp parse_document_list([], _validator, groups, _count),
    do: {:ok, %__MODULE__{groups: groups}}

  defp parse_document_list(
         [%LoadedDocument{document: document} | documents],
         validator,
         groups,
         count
       ) do
    with :ok <- validate_document(validator, document),
         {:ok, groups, count} <- collect_groups(document["event_groups"], groups, count) do
      parse_document_list(documents, validator, groups, count)
    end
  end

  defp parse_document_list(_documents, _validator, _groups, _count),
    do: {:error, :invalid_event_group_document}

  defp validate_document(validator, document) do
    case SchemaValidator.validate(validator, document) do
      :ok -> :ok
      {:error, :schema_violation} -> {:error, :invalid_event_group_document}
      {:error, :invalid_schema_validator} -> {:error, :invalid_event_group_schema}
    end
  end

  defp collect_groups(document_groups, groups, count) do
    document_groups
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, groups, count}, &collect_group/2)
  end

  defp collect_group({id, attributes}, {:ok, groups, count}) do
    cond do
      Map.has_key?(groups, id) ->
        {:halt, {:error, :duplicate_event_group}}

      count >= @max_groups ->
        {:halt, {:error, :too_many_event_groups}}

      true ->
        with {:ok, id} <- Value.id(id),
             {:ok, reply_probability} <- Value.probability(attributes["reply_probability"]) do
          group = %{id: id, reply_probability: reply_probability}
          {:cont, {:ok, Map.put(groups, id, group), count + 1}}
        else
          {:error, _reason} -> {:halt, {:error, :invalid_event_group_document}}
        end
    end
  end
end

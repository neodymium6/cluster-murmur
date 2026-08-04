defmodule ClusterMurmur.Config.Triggers do
  @moduledoc """
  Validates and combines version 1 event-trigger documents.

  Version 1 event triggers contain a bounded declarative matcher and one fixed
  start-conversation action. Binding IDs are normalized but remain unresolved
  until complete configuration assembly.
  """

  alias ClusterMurmur.Config.{Duration, EventMatcher, LoadedDocument, SchemaValidator, Value}
  alias ClusterMurmur.Triggers.EventTrigger

  @draft "http://json-schema.org/draft-07/schema#"
  @id_pattern "^[A-Za-z0-9][A-Za-z0-9._-]*$"
  @max_triggers 256

  @schema %{
    "$schema" => @draft,
    "type" => "object",
    "required" => ["triggers"],
    "additionalProperties" => false,
    "properties" => %{
      "triggers" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["id", "event", "action", "cooldown"],
          "additionalProperties" => false,
          "properties" => %{
            "id" => %{"type" => "string", "pattern" => @id_pattern},
            "event" => %{
              "type" => "object",
              "required" => ["match"],
              "additionalProperties" => false,
              "properties" => %{"match" => %{"type" => "object"}}
            },
            "action" => %{
              "type" => "object",
              "required" => ["type", "binding"],
              "additionalProperties" => false,
              "properties" => %{
                "type" => %{"type" => "string", "enum" => ["start_conversation"]},
                "binding" => %{"type" => "string", "pattern" => @id_pattern}
              }
            },
            "cooldown" => %{"type" => "string", "minLength" => 1, "maxLength" => 32}
          }
        }
      }
    }
  }

  @derive {Inspect, only: []}
  @enforce_keys [:triggers]
  defstruct [:triggers]

  @type t :: %__MODULE__{triggers: %{required(String.t()) => EventTrigger.t()}}
  @type error ::
          :duplicate_trigger
          | :invalid_trigger_document
          | :invalid_trigger_schema
          | :too_many_triggers

  @doc "Validates and combines decoded event-trigger documents."
  @spec parse_documents(term()) :: {:ok, t()} | {:error, error()}
  def parse_documents(documents) when is_list(documents) do
    with {:ok, validator} <- compile_schema(),
         {:ok, matcher_validator} <- compile_matcher_schema() do
      parse_document_list(documents, validator, matcher_validator, %{}, 0)
    end
  end

  def parse_documents(_documents), do: {:error, :invalid_trigger_document}

  defp compile_schema do
    case SchemaValidator.compile(@schema) do
      {:ok, validator} -> {:ok, validator}
      {:error, _reason} -> {:error, :invalid_trigger_schema}
    end
  end

  defp compile_matcher_schema do
    case EventMatcher.compile() do
      {:ok, validator} -> {:ok, validator}
      {:error, _reason} -> {:error, :invalid_trigger_schema}
    end
  end

  defp parse_document_list([], _validator, _matcher_validator, triggers, _count),
    do: {:ok, %__MODULE__{triggers: triggers}}

  defp parse_document_list(
         [%LoadedDocument{document: document} | documents],
         validator,
         matcher_validator,
         triggers,
         count
       ) do
    with :ok <- validate_document(validator, document),
         {:ok, triggers, count} <-
           collect_triggers(document["triggers"], matcher_validator, triggers, count) do
      parse_document_list(documents, validator, matcher_validator, triggers, count)
    end
  end

  defp parse_document_list(_documents, _validator, _matcher_validator, _triggers, _count),
    do: {:error, :invalid_trigger_document}

  defp validate_document(validator, document) do
    case SchemaValidator.validate(validator, document) do
      :ok -> :ok
      {:error, :schema_violation} -> {:error, :invalid_trigger_document}
      {:error, :invalid_schema_validator} -> {:error, :invalid_trigger_schema}
    end
  end

  defp collect_triggers(document_triggers, matcher_validator, triggers, count) do
    document_triggers
    |> Enum.sort_by(&Map.get(&1, "id"))
    |> Enum.reduce_while({:ok, triggers, count}, fn attributes, {:ok, triggers, count} ->
      collect_trigger(attributes, matcher_validator, triggers, count)
    end)
  end

  defp collect_trigger(attributes, matcher_validator, triggers, count) do
    id = attributes["id"]

    cond do
      Map.has_key?(triggers, id) ->
        {:halt, {:error, :duplicate_trigger}}

      count >= @max_triggers ->
        {:halt, {:error, :too_many_triggers}}

      true ->
        case build_trigger(attributes, matcher_validator) do
          {:ok, trigger} ->
            {:cont, {:ok, Map.put(triggers, trigger.id, trigger), count + 1}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end
  end

  defp build_trigger(attributes, matcher_validator) do
    with {:ok, id} <- validate_id(attributes["id"]),
         {:ok, matcher} <- validate_matcher(attributes["event"]["match"], matcher_validator),
         {:ok, binding} <- validate_id(attributes["action"]["binding"]),
         {:ok, cooldown_ms} <- validate_cooldown(attributes["cooldown"]) do
      {:ok,
       %EventTrigger{
         id: id,
         matcher: matcher,
         action: :start_conversation,
         binding: binding,
         cooldown_ms: cooldown_ms
       }}
    end
  end

  defp validate_id(value) do
    case Value.id(value) do
      {:ok, id} -> {:ok, id}
      {:error, _reason} -> {:error, :invalid_trigger_document}
    end
  end

  defp validate_matcher(document, matcher_validator) do
    case EventMatcher.parse(document, matcher_validator) do
      {:ok, matcher} -> {:ok, matcher}
      {:error, :invalid_event_matcher} -> {:error, :invalid_trigger_document}
      {:error, :invalid_event_matcher_schema} -> {:error, :invalid_trigger_schema}
    end
  end

  defp validate_cooldown(value) do
    case Duration.parse(value) do
      {:ok, milliseconds} -> {:ok, milliseconds}
      {:error, _reason} -> {:error, :invalid_trigger_document}
    end
  end
end

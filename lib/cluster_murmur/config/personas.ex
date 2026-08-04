defmodule ClusterMurmur.Config.Personas do
  @moduledoc """
  Validates and combines version 1 persona documents and their prompts.

  Structural validation precedes bounded prompt reads. Semantic validation
  applies shared scalar rules, normalizes optional values, and rejects
  duplicate IDs across documents without returning source paths or values.
  """

  alias ClusterMurmur.Config.{Duration, LoadedDocument, PathResolver, PromptReader}
  alias ClusterMurmur.Config.{SchemaValidator, Value}
  alias ClusterMurmur.Personas.Persona

  @draft "http://json-schema.org/draft-07/schema#"
  @id_pattern "^[A-Za-z0-9][A-Za-z0-9._-]*$"
  @max_personas 256
  @max_display_name_bytes 128
  @max_avatar_bytes 2_048

  @schema %{
    "$schema" => @draft,
    "type" => "object",
    "required" => ["personas"],
    "additionalProperties" => false,
    "properties" => %{
      "personas" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["id", "display_name", "prompt_file"],
          "additionalProperties" => false,
          "properties" => %{
            "id" => %{"type" => "string", "pattern" => @id_pattern},
            "display_name" => %{"type" => "string", "minLength" => 1},
            "avatar" => %{"type" => "string", "minLength" => 1},
            "prompt_file" => %{"type" => "string", "minLength" => 1, "maxLength" => 512},
            "enabled" => %{"type" => "boolean"},
            "interests" => %{
              "type" => "object",
              "maxProperties" => 256,
              "propertyNames" => %{"pattern" => @id_pattern},
              "additionalProperties" => %{"type" => "number", "minimum" => 0}
            },
            "behavior" => %{
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{
                "spontaneous_weight" => %{"type" => "number", "minimum" => 0},
                "reply_weight" => %{"type" => "number", "minimum" => 0},
                "cooldown" => %{"type" => "string"}
              }
            },
            "relationships" => %{"type" => "object", "maxProperties" => 0},
            "metadata" => %{"type" => "object", "maxProperties" => 0}
          }
        }
      }
    }
  }

  @derive {Inspect, only: []}
  @enforce_keys [:personas]
  defstruct [:personas]

  @type t :: %__MODULE__{personas: %{required(String.t()) => Persona.t()}}
  @type error ::
          :duplicate_persona
          | :invalid_persona_document
          | :invalid_persona_schema
          | :too_many_personas
          | {:prompt, PromptReader.error()}

  @doc "Validates persona documents and reads each referenced prompt."
  @spec parse_documents(Path.t(), term()) :: {:ok, t()} | {:error, error()}
  def parse_documents(config_path, documents)
      when is_binary(config_path) and is_list(documents) do
    with {:ok, _root} <- validate_config_path(config_path),
         {:ok, validator} <- compile_schema() do
      parse_document_list(config_path, documents, validator, %{}, 0)
    end
  end

  def parse_documents(config_path, _documents) when not is_binary(config_path),
    do: {:error, {:prompt, :invalid_config_path}}

  def parse_documents(_config_path, _documents), do: {:error, :invalid_persona_document}

  defp validate_config_path(config_path) do
    case PathResolver.config_root(config_path) do
      {:ok, root} -> {:ok, root}
      {:error, reason} -> {:error, {:prompt, reason}}
    end
  end

  defp compile_schema do
    case SchemaValidator.compile(@schema) do
      {:ok, validator} -> {:ok, validator}
      {:error, _reason} -> {:error, :invalid_persona_schema}
    end
  end

  defp parse_document_list(_config_path, [], _validator, personas, _count),
    do: {:ok, %__MODULE__{personas: personas}}

  defp parse_document_list(
         config_path,
         [%LoadedDocument{path: source_path, document: document} | documents],
         validator,
         personas,
         count
       ) do
    with :ok <- validate_document(validator, document),
         {:ok, personas, count} <-
           collect_personas(config_path, source_path, document["personas"], personas, count) do
      parse_document_list(config_path, documents, validator, personas, count)
    end
  end

  defp parse_document_list(_config_path, _documents, _validator, _personas, _count),
    do: {:error, :invalid_persona_document}

  defp validate_document(validator, document) do
    case SchemaValidator.validate(validator, document) do
      :ok -> :ok
      {:error, :schema_violation} -> {:error, :invalid_persona_document}
      {:error, :invalid_schema_validator} -> {:error, :invalid_persona_schema}
    end
  end

  defp collect_personas(config_path, source_path, document_personas, personas, count) do
    document_personas
    |> Enum.sort_by(&Map.get(&1, "id"))
    |> Enum.reduce_while({:ok, personas, count}, fn attributes, {:ok, personas, count} ->
      collect_persona(config_path, source_path, attributes, personas, count)
    end)
  end

  defp collect_persona(config_path, source_path, attributes, personas, count) do
    id = attributes["id"]

    cond do
      Map.has_key?(personas, id) ->
        {:halt, {:error, :duplicate_persona}}

      count >= @max_personas ->
        {:halt, {:error, :too_many_personas}}

      true ->
        case build_persona(config_path, source_path, attributes) do
          {:ok, persona} ->
            {:cont, {:ok, Map.put(personas, persona.id, persona), count + 1}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end
  end

  defp build_persona(config_path, source_path, attributes) do
    with {:ok, id} <- validate_id(attributes["id"]),
         {:ok, display_name} <- validate_display_name(attributes["display_name"]),
         {:ok, avatar} <- validate_avatar(Map.get(attributes, "avatar")),
         {:ok, interests} <- validate_interests(Map.get(attributes, "interests", %{})),
         {:ok, behavior} <- validate_behavior(Map.get(attributes, "behavior", %{})),
         {:ok, prompt} <- read_prompt(config_path, source_path, attributes["prompt_file"]) do
      {:ok,
       %Persona{
         id: id,
         display_name: display_name,
         avatar: avatar,
         prompt: prompt,
         enabled: Map.get(attributes, "enabled", true),
         interests: interests,
         behavior: behavior,
         relationships: %{},
         metadata: %{}
       }}
    end
  end

  defp validate_id(value) do
    case Value.id(value) do
      {:ok, id} -> {:ok, id}
      {:error, _reason} -> {:error, :invalid_persona_document}
    end
  end

  defp validate_display_name(value) do
    if is_binary(value) and String.valid?(value) and
         byte_size(value) <= @max_display_name_bytes and
         String.trim(value) != "" do
      {:ok, value}
    else
      {:error, :invalid_persona_document}
    end
  end

  defp validate_avatar(nil), do: {:ok, nil}

  defp validate_avatar(value) when is_binary(value) and byte_size(value) <= @max_avatar_bytes do
    with true <- String.valid?(value),
         :ok <- validate_uri_encoding(value),
         {:ok, %URI{scheme: "https", host: host, userinfo: nil}} <- URI.new(value),
         true <- is_binary(host) and host != "" do
      {:ok, value}
    else
      _failure -> {:error, :invalid_persona_document}
    end
  end

  defp validate_avatar(_value), do: {:error, :invalid_persona_document}

  defp validate_uri_encoding(value) do
    if Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value) do
      {:error, :invalid_uri}
    else
      case :uri_string.normalize(value) do
        normalized when is_binary(normalized) -> :ok
        _error -> {:error, :invalid_uri}
      end
    end
  rescue
    _error -> {:error, :invalid_uri}
  catch
    _kind, _reason -> {:error, :invalid_uri}
  end

  defp validate_interests(interests) do
    interests
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {group_id, weight}, {:ok, validated} ->
      with {:ok, group_id} <- Value.id(group_id),
           {:ok, weight} <- Value.weight(weight) do
        {:cont, {:ok, Map.put(validated, group_id, weight)}}
      else
        {:error, _reason} -> {:halt, {:error, :invalid_persona_document}}
      end
    end)
  end

  defp validate_behavior(behavior) do
    behavior
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, &validate_behavior_entry/2)
  end

  defp validate_behavior_entry({key, value}, {:ok, validated})
       when key in ["spontaneous_weight", "reply_weight"] do
    case Value.weight(value) do
      {:ok, weight} -> {:cont, {:ok, Map.put(validated, key, weight)}}
      {:error, _reason} -> {:halt, {:error, :invalid_persona_document}}
    end
  end

  defp validate_behavior_entry({"cooldown", value}, {:ok, validated}) do
    case Duration.parse(value) do
      {:ok, milliseconds} -> {:cont, {:ok, Map.put(validated, "cooldown_ms", milliseconds)}}
      {:error, _reason} -> {:halt, {:error, :invalid_persona_document}}
    end
  end

  defp read_prompt(config_path, source_path, reference) do
    case PromptReader.read(config_path, source_path, reference) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, {:prompt, reason}}
    end
  end
end

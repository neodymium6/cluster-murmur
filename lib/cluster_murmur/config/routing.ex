defmodule ClusterMurmur.Config.Routing do
  @moduledoc """
  Validates the single version 1 Discord routing destination.

  Configuration stores only the name of an environment variable whose value is
  a mounted secret-file path. Reading the file and validating the webhook URL
  remain a separate startup boundary.
  """

  alias ClusterMurmur.Config.{LoadedDocument, SchemaValidator, Value}

  @draft "http://json-schema.org/draft-07/schema#"
  @environment_variable_pattern "^[A-Za-z_][A-Za-z0-9_]*$"

  @schema %{
    "$schema" => @draft,
    "type" => "object",
    "required" => ["routing"],
    "additionalProperties" => false,
    "properties" => %{
      "routing" => %{
        "type" => "object",
        "required" => ["default"],
        "additionalProperties" => false,
        "properties" => %{
          "default" => %{
            "type" => "object",
            "required" => ["webhook_secret_file_env"],
            "additionalProperties" => false,
            "properties" => %{
              "webhook_secret_file_env" => %{
                "type" => "string",
                "minLength" => 1,
                "maxLength" => 128,
                "pattern" => @environment_variable_pattern
              }
            }
          }
        }
      }
    }
  }

  @derive {Inspect, only: []}
  @enforce_keys [:webhook_secret_file_env]
  defstruct [:webhook_secret_file_env]

  @type t :: %__MODULE__{webhook_secret_file_env: String.t()}
  @type error ::
          :duplicate_default_route
          | :invalid_routing_document
          | :invalid_routing_schema
          | :missing_default_route

  @doc "Validates exactly one decoded default-routing document."
  @spec parse_documents(term()) :: {:ok, t()} | {:error, error()}
  def parse_documents(documents) when is_list(documents) do
    with {:ok, documents} <- validate_document_collection(documents) do
      parse_document_collection(documents)
    end
  end

  def parse_documents(_documents), do: {:error, :invalid_routing_document}

  defp compile_schema do
    case SchemaValidator.compile(@schema) do
      {:ok, validator} -> {:ok, validator}
      {:error, _reason} -> {:error, :invalid_routing_schema}
    end
  end

  defp validate_document_collection(documents),
    do: validate_document_collection(documents, [])

  defp validate_document_collection([], documents), do: {:ok, Enum.reverse(documents)}

  defp validate_document_collection([%LoadedDocument{} = document | documents], validated),
    do: validate_document_collection(documents, [document | validated])

  defp validate_document_collection(_documents, _validated),
    do: {:error, :invalid_routing_document}

  defp parse_document_collection([]), do: {:error, :missing_default_route}

  defp parse_document_collection([_first, _second | _documents]),
    do: {:error, :duplicate_default_route}

  defp parse_document_collection([%LoadedDocument{document: document}]) do
    with {:ok, validator} <- compile_schema(),
         :ok <- validate_document(validator, document),
         {:ok, routing} <- build_routing(document) do
      {:ok, routing}
    end
  end

  defp validate_document(validator, document) do
    case SchemaValidator.validate(validator, document) do
      :ok -> :ok
      {:error, :schema_violation} -> {:error, :invalid_routing_document}
      {:error, :invalid_schema_validator} -> {:error, :invalid_routing_schema}
    end
  end

  defp build_routing(document) do
    value = document["routing"]["default"]["webhook_secret_file_env"]

    case Value.environment_variable_name(value) do
      {:ok, name} -> {:ok, %__MODULE__{webhook_secret_file_env: name}}
      {:error, _reason} -> {:error, :invalid_routing_document}
    end
  end
end

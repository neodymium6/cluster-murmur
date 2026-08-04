defmodule ClusterMurmur.Config.SchemaValidator do
  @moduledoc """
  Compiles trusted JSON Schemas and validates bounded decoded documents.

  Schemas are application-owned Draft 7 maps. References and
  reference-rebasing identifiers are rejected before the schema library
  resolves them. Content-decoding keywords are also rejected so validation
  cannot delegate document values to a global decoder. Validation failures
  collapse to a stable atom so paths and rejected configuration values do not
  escape this boundary.
  """

  alias ExJsonSchema.{Schema, Validator}

  @draft "http://json-schema.org/draft-07/schema#"
  @literal_keywords ["const", "default", "enum", "examples"]
  @schema_map_keywords ["definitions", "patternProperties", "properties"]
  @schema_list_keywords ["allOf", "anyOf", "oneOf"]
  @schema_value_keywords [
    "additionalItems",
    "additionalProperties",
    "contains",
    "else",
    "if",
    "not",
    "propertyNames",
    "then"
  ]

  defmodule Compiled do
    @moduledoc "A compiled application-owned schema with redacted inspection."

    @derive {Inspect, only: []}
    @enforce_keys [:root]
    defstruct [:root]

    @opaque t :: %__MODULE__{root: ExJsonSchema.Schema.Root.t()}
  end

  defmodule LocalFormatValidator do
    @moduledoc false

    def validate(_unknown_format, _document_value), do: true
  end

  @type compile_error ::
          :invalid_schema | :unsupported_schema_feature | :unsupported_schema_reference
  @type validation_error :: :invalid_schema_validator | :schema_violation

  @doc """
  Compiles one application-owned Draft 7 schema without resolving references.
  """
  @spec compile(term()) :: {:ok, Compiled.t()} | {:error, compile_error()}
  def compile(%{"$schema" => @draft} = schema) do
    with :ok <- validate_json_value(schema),
         :ok <- validate_schema(schema) do
      resolve(schema)
    end
  end

  def compile(_schema), do: {:error, :invalid_schema}

  @doc """
  Validates one already-bounded decoded document without returning library errors.
  """
  @spec validate(Compiled.t(), term()) :: :ok | {:error, validation_error()}
  def validate(%Compiled{root: %Schema.Root{} = root}, document) do
    with :ok <- validate_compiled_root(root),
         :ok <- validate_document_value(document) do
      validate_document(root, document)
    end
  end

  def validate(_compiled, _document), do: {:error, :invalid_schema_validator}

  defp resolve(schema) do
    root =
      Schema.resolve(schema,
        custom_format_validator: {LocalFormatValidator, :validate}
      )

    {:ok, %Compiled{root: root}}
  rescue
    _error -> {:error, :invalid_schema}
  end

  defp validate_compiled_root(
         %Schema.Root{
           schema: %{"$schema" => @draft} = schema,
           refs: refs,
           location: :root,
           version: 7,
           custom_format_validator: {LocalFormatValidator, :validate}
         } = root
       )
       when is_map(refs) and map_size(refs) == 0 do
    with :ok <- validate_json_value(schema),
         :ok <- validate_schema(schema),
         :ok <- validate_canonical_root(root, schema) do
      :ok
    else
      _error -> {:error, :invalid_schema_validator}
    end
  end

  defp validate_compiled_root(_root), do: {:error, :invalid_schema_validator}

  defp validate_canonical_root(root, schema) do
    case resolve(schema) do
      {:ok, %Compiled{root: ^root}} -> :ok
      _error -> {:error, :invalid_schema_validator}
    end
  end

  defp validate_document(root, document) do
    case Validator.validate(root, document, error_formatter: false) do
      :ok -> :ok
      {:error, _errors} -> {:error, :schema_violation}
    end
  rescue
    _error -> {:error, :invalid_schema_validator}
  catch
    _kind, _reason -> {:error, :invalid_schema_validator}
  end

  defp validate_document_value(document) do
    case validate_json_value(document) do
      :ok -> :ok
      {:error, :invalid_schema} -> {:error, :schema_violation}
    end
  end

  defp validate_json_value(nil), do: :ok
  defp validate_json_value(value) when is_boolean(value), do: :ok
  defp validate_json_value(value) when is_integer(value) or is_float(value), do: :ok

  defp validate_json_value(value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: {:error, :invalid_schema}
  end

  defp validate_json_value(%{__struct__: _module}), do: {:error, :invalid_schema}

  defp validate_json_value(%{} = value) do
    if Enum.all?(Map.keys(value), &(is_binary(&1) and String.valid?(&1))) do
      reduce_entries(value, fn {_key, nested} -> validate_json_value(nested) end)
    else
      {:error, :invalid_schema}
    end
  end

  defp validate_json_value(values) when is_list(values),
    do: validate_proper_list(values, &validate_json_value/1)

  defp validate_json_value(_value), do: {:error, :invalid_schema}

  defp validate_schema(schema) when is_boolean(schema), do: :ok
  defp validate_schema(%{__struct__: _module}), do: {:error, :invalid_schema}

  defp validate_schema(%{} = schema) do
    with :ok <- validate_current_schema(schema) do
      reduce_entries(schema, &validate_schema_entry/1)
    end
  end

  defp validate_schema(values) when is_list(values), do: validate_schema_list(values)
  defp validate_schema(_value), do: :ok

  defp validate_current_schema(schema) do
    with :ok <- reject_identifier(Map.has_key?(schema, "$id")),
         :ok <- reject_identifier(is_binary(Map.get(schema, "id"))),
         :ok <- validate_optional_reference(Map.fetch(schema, "$ref")),
         :ok <- reject_content_keywords(schema) do
      :ok
    end
  end

  defp reject_identifier(true), do: {:error, :unsupported_schema_reference}
  defp reject_identifier(false), do: :ok

  defp validate_optional_reference({:ok, reference}), do: validate_reference(reference)
  defp validate_optional_reference(:error), do: :ok

  defp validate_reference(_reference), do: {:error, :unsupported_schema_reference}

  defp reject_content_keywords(schema) do
    if is_binary(Map.get(schema, "contentEncoding")) or
         is_binary(Map.get(schema, "contentMediaType")),
       do: {:error, :unsupported_schema_feature},
       else: :ok
  end

  defp validate_schema_entry({key, _literal}) when key in @literal_keywords, do: :ok

  defp validate_schema_entry({key, schemas})
       when key in @schema_map_keywords and is_map(schemas) and not is_struct(schemas),
       do: validate_schema_list(sorted_values(schemas))

  defp validate_schema_entry({key, schemas})
       when key in @schema_list_keywords and is_list(schemas),
       do: validate_schema_list(schemas)

  defp validate_schema_entry({key, schema}) when key in @schema_value_keywords,
    do: validate_schema(schema)

  defp validate_schema_entry({"items", schemas}) when is_list(schemas),
    do: validate_schema_list(schemas)

  defp validate_schema_entry({"items", schema}), do: validate_schema(schema)

  defp validate_schema_entry({"dependencies", dependencies})
       when is_map(dependencies) and not is_struct(dependencies),
       do: validate_schema_list(sorted_values(dependencies))

  defp validate_schema_entry({_key, nested}), do: validate_resolver_tree(nested)

  defp validate_schema_list(values), do: validate_proper_list(values, &validate_schema/1)

  defp validate_resolver_tree(%{__struct__: _module}), do: {:error, :invalid_schema}

  defp validate_resolver_tree(%{} = value) do
    with :ok <- validate_current_schema(value) do
      reduce_entries(value, fn
        {key, _literal} when key in @literal_keywords -> :ok
        {_key, nested} -> validate_resolver_tree(nested)
      end)
    end
  end

  defp validate_resolver_tree(values) when is_list(values),
    do: validate_proper_list(values, &validate_resolver_tree/1)

  defp validate_resolver_tree(_value), do: :ok

  defp reduce_entries(map, validator) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      entry |> validator.() |> continue_or_halt()
    end)
  end

  defp sorted_values(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp validate_proper_list([], _validator), do: :ok

  defp validate_proper_list([value | remaining], validator) do
    with :ok <- validator.(value) do
      validate_proper_list(remaining, validator)
    end
  end

  defp validate_proper_list(_improper_tail, _validator), do: {:error, :invalid_schema}

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt({:error, _reason} = error), do: {:halt, error}
end

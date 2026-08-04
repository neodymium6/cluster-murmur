defmodule ClusterMurmur.Config.EventMatcher do
  @moduledoc """
  Validates version 1 declarative event matchers.

  A matcher is a bounded conjunction over an allowlisted event field. Operators
  have fixed scalar shapes and cannot contain executable expressions or
  arbitrary field paths.
  """

  alias ClusterMurmur.Config.SchemaValidator
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate

  @draft "http://json-schema.org/draft-07/schema#"
  @operators ["equals", "not_equals", "in", "exists", "greater_than", "less_than"]
  @top_level_fields ["type", "source", "subject", "group", "severity"]
  @dynamic_key_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @max_predicates 32
  @max_values 32
  @max_field_bytes 512
  @max_string_value_bytes 1_024
  @max_safe_integer DomainLimits.max_safe_integer()
  @max_float DomainLimits.max_float()

  @schema %{
    "$schema" => @draft,
    "type" => "object",
    "required" => ["all"],
    "additionalProperties" => false,
    "properties" => %{
      "all" => %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => @max_predicates,
        "items" => %{
          "type" => "object",
          "required" => ["field", "operator"],
          "additionalProperties" => false,
          "properties" => %{
            "field" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_field_bytes},
            "operator" => %{"type" => "string", "enum" => @operators},
            "value" => %{},
            "values" => %{"type" => "array", "minItems" => 1, "maxItems" => @max_values}
          }
        }
      }
    }
  }

  @type error :: :invalid_event_matcher | :invalid_event_matcher_schema

  @doc "Compiles the application-owned matcher schema for repeated parsing."
  @spec compile() :: {:ok, SchemaValidator.Compiled.t()} | {:error, :invalid_event_matcher_schema}
  def compile do
    case SchemaValidator.compile(@schema) do
      {:ok, validator} -> {:ok, validator}
      {:error, _reason} -> {:error, :invalid_event_matcher_schema}
    end
  end

  @doc "Validates and normalizes one matcher, compiling its schema for this call."
  @spec parse(term()) :: {:ok, Matcher.t()} | {:error, error()}
  def parse(document) do
    with {:ok, validator} <- compile() do
      parse(document, validator)
    end
  end

  @doc "Validates and normalizes one matcher with a previously compiled schema."
  @spec parse(term(), SchemaValidator.Compiled.t()) :: {:ok, Matcher.t()} | {:error, error()}
  def parse(document, validator) do
    case SchemaValidator.validate(validator, document) do
      :ok -> normalize_document(document)
      {:error, :schema_violation} -> {:error, :invalid_event_matcher}
      {:error, :invalid_schema_validator} -> {:error, :invalid_event_matcher_schema}
    end
  end

  defp normalize_document(%{"all" => predicates} = document) when map_size(document) == 1,
    do: normalize_predicates(predicates)

  defp normalize_document(_document), do: {:error, :invalid_event_matcher}

  defp normalize_predicates(predicates)
       when is_list(predicates) and predicates != [] and length(predicates) <= @max_predicates do
    predicates
    |> Enum.reduce_while({:ok, []}, &normalize_predicate/2)
    |> case do
      {:ok, normalized} ->
        {:ok, %Matcher{predicates: Enum.sort(Enum.reverse(normalized))}}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_predicates(_predicates), do: {:error, :invalid_event_matcher}

  defp normalize_predicate(document, {:ok, predicates})
       when is_map(document) and not is_struct(document) do
    with {:ok, field} <- validate_field(document["field"]),
         {:ok, predicate} <- build_predicate(field, document),
         false <- Enum.any?(predicates, &(&1 == predicate)) do
      {:cont, {:ok, [predicate | predicates]}}
    else
      _failure -> {:halt, {:error, :invalid_event_matcher}}
    end
  end

  defp normalize_predicate(_document, _accumulator),
    do: {:halt, {:error, :invalid_event_matcher}}

  defp validate_field(field) when is_binary(field) and byte_size(field) <= @max_field_bytes do
    cond do
      field in @top_level_fields ->
        {:ok, field}

      String.starts_with?(field, "labels.") ->
        validate_dynamic_field(field, "labels.")

      String.starts_with?(field, "facts.") ->
        validate_dynamic_field(field, "facts.")

      true ->
        {:error, :invalid_event_matcher}
    end
  end

  defp validate_field(_field), do: {:error, :invalid_event_matcher}

  defp validate_dynamic_field(field, prefix) do
    key = String.replace_prefix(field, prefix, "")

    if String.valid?(key) and Regex.match?(@dynamic_key_pattern, key),
      do: {:ok, field},
      else: {:error, :invalid_event_matcher}
  end

  defp build_predicate(
         field,
         %{
           "operator" => operator,
           "value" => value
         } = document
       )
       when operator in ["equals", "not_equals"] do
    with true <- exact_keys?(document, ["field", "operator", "value"]),
         {:ok, value} <- validate_scalar(value) do
      {:ok, %Predicate{field: field, operator: operator_atom(operator), value: value}}
    else
      _failure -> {:error, :invalid_event_matcher}
    end
  end

  defp build_predicate(field, %{"operator" => "in", "values" => values} = document) do
    with true <- exact_keys?(document, ["field", "operator", "values"]),
         {:ok, values} <- validate_values(values) do
      {:ok, %Predicate{field: field, operator: :in, values: values}}
    else
      _failure -> {:error, :invalid_event_matcher}
    end
  end

  defp build_predicate(field, %{"operator" => "exists"} = document) do
    if exact_keys?(document, ["field", "operator"]),
      do: {:ok, %Predicate{field: field, operator: :exists}},
      else: {:error, :invalid_event_matcher}
  end

  defp build_predicate(field, %{"operator" => operator, "value" => value} = document)
       when operator in ["greater_than", "less_than"] and is_number(value) do
    with true <- exact_keys?(document, ["field", "operator", "value"]),
         {:ok, value} <- validate_scalar(value) do
      {:ok, %Predicate{field: field, operator: operator_atom(operator), value: value}}
    else
      _failure -> {:error, :invalid_event_matcher}
    end
  end

  defp build_predicate(_field, _document), do: {:error, :invalid_event_matcher}

  defp validate_values(values)
       when is_list(values) and values != [] and length(values) <= @max_values do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, validated} ->
      case validate_scalar(value) do
        {:ok, value} -> {:cont, {:ok, [value | validated]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, validated} ->
        values = Enum.sort(validated)

        if pairwise_distinct?(values),
          do: {:ok, values},
          else: {:error, :invalid_event_matcher}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_values(_values), do: {:error, :invalid_event_matcher}

  defp validate_scalar(value) when is_nil(value) or is_boolean(value),
    do: {:ok, value}

  defp validate_scalar(value)
       when is_integer(value) and value >= -@max_safe_integer and value <= @max_safe_integer,
       do: {:ok, value}

  defp validate_scalar(value) when is_float(value) do
    if value == value and value >= -@max_float and value <= @max_float,
      do: {:ok, value},
      else: {:error, :invalid_event_matcher}
  end

  defp validate_scalar(value)
       when is_binary(value) and byte_size(value) <= @max_string_value_bytes do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_event_matcher}
  end

  defp validate_scalar(_value), do: {:error, :invalid_event_matcher}

  defp pairwise_distinct?([]), do: true

  defp pairwise_distinct?([value | rest]) do
    not Enum.any?(rest, &(&1 == value)) and pairwise_distinct?(rest)
  end

  defp operator_atom("equals"), do: :equals
  defp operator_atom("not_equals"), do: :not_equals
  defp operator_atom("greater_than"), do: :greater_than
  defp operator_atom("less_than"), do: :less_than

  defp exact_keys?(document, expected), do: Enum.sort(Map.keys(document)) == Enum.sort(expected)
end

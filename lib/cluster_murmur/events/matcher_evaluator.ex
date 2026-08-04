defmodule ClusterMurmur.Events.MatcherEvaluator do
  @moduledoc """
  Deterministically evaluates validated event matchers.

  Evaluation reads only the matcher's fixed field allowlist. Invalid forged
  domain values fail with stable atoms and never expose event facts in errors.
  """

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate
  alias ClusterMurmur.Events.Validator
  alias ClusterMurmur.DomainLimits

  @top_level_fields ["type", "source", "subject", "group", "severity"]
  @dynamic_key_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @max_predicates 32
  @max_values 32
  @max_field_bytes 512
  @max_string_value_bytes 1_024
  @max_safe_integer DomainLimits.max_safe_integer()
  @max_float DomainLimits.max_float()
  @matcher_keys Matcher.__struct__() |> Map.keys()
  @matcher_key_count length(@matcher_keys)
  @predicate_keys Predicate.__struct__() |> Map.keys()
  @predicate_key_count length(@predicate_keys)

  @type error :: :invalid_event | :invalid_matcher

  @doc "Returns whether every matcher predicate matches the supplied event."
  @spec match(term(), term()) :: {:ok, boolean()} | {:error, error()}
  def match(%Matcher{} = matcher, %Event{} = event) do
    with :ok <- Validator.validate(event),
         :ok <- validate(matcher) do
      {:ok, Enum.all?(matcher.predicates, &predicate_matches?(&1, event))}
    end
  end

  def match(%Matcher{}, _event), do: {:error, :invalid_event}
  def match(_matcher, _event), do: {:error, :invalid_matcher}

  @doc "Validates one exact bounded runtime matcher shape."
  @spec validate(term()) :: :ok | {:error, :invalid_matcher}
  def validate(%Matcher{predicates: [_predicate | _predicates] = predicates} = matcher) do
    if exact_keys?(matcher, @matcher_keys, @matcher_key_count) do
      validate_predicates(predicates, [], 0)
    else
      {:error, :invalid_matcher}
    end
  end

  def validate(_matcher), do: {:error, :invalid_matcher}

  defp validate_predicates([], _validated, _count), do: :ok

  defp validate_predicates([_predicate | _predicates], _validated, @max_predicates),
    do: {:error, :invalid_matcher}

  defp validate_predicates([predicate | predicates], validated, count) do
    with :ok <- validate_predicate(predicate),
         false <- Enum.any?(validated, &(&1 == predicate)) do
      validate_predicates(predicates, [predicate | validated], count + 1)
    else
      _failure -> {:error, :invalid_matcher}
    end
  end

  defp validate_predicates(_improper_tail, _validated, _count),
    do: {:error, :invalid_matcher}

  defp validate_predicate(
         %Predicate{field: field, operator: operator, value: value, values: []} = predicate
       )
       when operator in [:equals, :not_equals] do
    with true <- exact_predicate?(predicate),
         :ok <- validate_field(field),
         :ok <- validate_scalar(value),
         do: :ok
  end

  defp validate_predicate(
         %Predicate{
           field: field,
           operator: :in,
           value: nil,
           values: [_value | _values] = values
         } = predicate
       ) do
    with true <- exact_predicate?(predicate),
         :ok <- validate_field(field),
         :ok <- validate_values(values, [], 0) do
      :ok
    else
      _failure -> {:error, :invalid_matcher}
    end
  end

  defp validate_predicate(
         %Predicate{
           field: field,
           operator: :exists,
           value: nil,
           values: []
         } = predicate
       ),
       do: with(true <- exact_predicate?(predicate), :ok <- validate_field(field), do: :ok)

  defp validate_predicate(
         %Predicate{field: field, operator: operator, value: value, values: []} = predicate
       )
       when operator in [:greater_than, :less_than] and is_number(value),
       do:
         with(
           true <- exact_predicate?(predicate),
           :ok <- validate_field(field),
           :ok <- validate_scalar(value),
           do: :ok
         )

  defp validate_predicate(_predicate), do: {:error, :invalid_matcher}

  defp validate_field(field) when is_binary(field) and byte_size(field) <= @max_field_bytes do
    cond do
      field in @top_level_fields ->
        :ok

      String.starts_with?(field, "labels.") ->
        validate_dynamic_key(String.replace_prefix(field, "labels.", ""))

      String.starts_with?(field, "facts.") ->
        validate_dynamic_key(String.replace_prefix(field, "facts.", ""))

      true ->
        {:error, :invalid_matcher}
    end
  end

  defp validate_field(_field), do: {:error, :invalid_matcher}

  defp validate_dynamic_key(key) do
    if String.valid?(key) and Regex.match?(@dynamic_key_pattern, key),
      do: :ok,
      else: {:error, :invalid_matcher}
  end

  defp validate_scalar(value) when is_nil(value) or is_boolean(value), do: :ok

  defp validate_scalar(value)
       when is_integer(value) and value >= -@max_safe_integer and value <= @max_safe_integer,
       do: :ok

  defp validate_scalar(value) when is_float(value) do
    if value == value and value >= -@max_float and value <= @max_float,
      do: :ok,
      else: {:error, :invalid_matcher}
  end

  defp validate_scalar(value)
       when is_binary(value) and byte_size(value) <= @max_string_value_bytes do
    if String.valid?(value), do: :ok, else: {:error, :invalid_matcher}
  end

  defp validate_scalar(_value), do: {:error, :invalid_matcher}

  defp predicate_matches?(%Predicate{field: field, operator: operator} = predicate, event) do
    case resolve_field(field, event) do
      {:present, value} -> compare(operator, value, predicate)
      :missing -> false
    end
  end

  defp resolve_field(field, event) when field in @top_level_fields do
    {:present, Map.fetch!(event, String.to_existing_atom(field))}
  end

  defp resolve_field("labels." <> key, event), do: resolve_key(event.labels, key)
  defp resolve_field("facts." <> key, event), do: resolve_key(event.facts, key)

  defp resolve_key(values, key) do
    case Map.fetch(values, key) do
      {:ok, value} -> {:present, value}
      :error -> :missing
    end
  end

  defp compare(:equals, actual, %Predicate{value: expected}),
    do: event_scalar?(actual) and actual == expected

  defp compare(:not_equals, actual, %Predicate{value: expected}),
    do: event_scalar?(actual) and actual != expected

  defp compare(:in, actual, %Predicate{values: expected}),
    do: event_scalar?(actual) and Enum.any?(expected, &(&1 == actual))

  defp compare(:exists, actual, _predicate), do: not is_nil(actual)

  defp compare(:greater_than, actual, %Predicate{value: expected}) when is_number(actual),
    do: actual > expected

  defp compare(:less_than, actual, %Predicate{value: expected}) when is_number(actual),
    do: actual < expected

  defp compare(_operator, _actual, _predicate), do: false

  defp event_scalar?(value) when is_nil(value) or is_boolean(value) or is_number(value), do: true
  defp event_scalar?(value) when is_binary(value), do: String.valid?(value)
  defp event_scalar?(_value), do: false

  defp validate_values([], _validated, _count), do: :ok

  defp validate_values([_value | _values], _validated, @max_values),
    do: {:error, :invalid_matcher}

  defp validate_values([value | values], validated, count) do
    with :ok <- validate_scalar(value),
         false <- Enum.any?(validated, &(&1 == value)) do
      validate_values(values, [value | validated], count + 1)
    else
      _failure -> {:error, :invalid_matcher}
    end
  end

  defp validate_values(_improper_tail, _validated, _count),
    do: {:error, :invalid_matcher}

  defp exact_predicate?(predicate),
    do: exact_keys?(predicate, @predicate_keys, @predicate_key_count)

  defp exact_keys?(value, keys, key_count) do
    map_size(value) == key_count and Enum.all?(keys, &Map.has_key?(value, &1))
  end
end

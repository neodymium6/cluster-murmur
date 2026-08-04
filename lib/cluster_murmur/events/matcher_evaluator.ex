defmodule ClusterMurmur.Events.MatcherEvaluator do
  @moduledoc """
  Deterministically evaluates validated event matchers.

  Evaluation reads only the matcher's fixed field allowlist. Invalid forged
  domain values fail with stable atoms and never expose event facts in errors.
  """

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Events.Matcher
  alias ClusterMurmur.Events.Matcher.Predicate

  @top_level_fields ["type", "source", "subject", "group", "severity"]
  @dynamic_key_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @max_predicates 32
  @max_values 32
  @max_field_bytes 512
  @max_string_value_bytes 1_024

  @type error :: :invalid_event | :invalid_matcher

  @doc "Returns whether every matcher predicate matches the supplied event."
  @spec match(term(), term()) :: {:ok, boolean()} | {:error, error()}
  def match(%Matcher{} = matcher, %Event{} = event) do
    with :ok <- validate_event(event),
         :ok <- validate_matcher(matcher) do
      {:ok, Enum.all?(matcher.predicates, &predicate_matches?(&1, event))}
    end
  end

  def match(%Matcher{}, _event), do: {:error, :invalid_event}
  def match(_matcher, _event), do: {:error, :invalid_matcher}

  defp validate_event(%Event{
         id: id,
         type: type,
         source: source,
         subject: subject,
         group: group,
         severity: severity,
         occurred_at: %DateTime{} = occurred_at,
         observed_at: observed_at,
         dedupe_key: dedupe_key,
         correlation_key: correlation_key,
         facts: facts,
         labels: labels
       })
       when is_binary(id) and is_binary(type) and is_binary(source) and
              (is_nil(subject) or is_binary(subject)) and
              (is_nil(group) or is_binary(group)) and
              (is_nil(severity) or is_binary(severity)) and
              is_map(facts) and not is_struct(facts) and is_map(labels) and not is_struct(labels),
       do:
         validate_event_values(
           [id, type, source, subject, group, severity, dedupe_key, correlation_key],
           occurred_at,
           observed_at
         )

  defp validate_event(_event), do: {:error, :invalid_event}

  defp validate_matcher(%Matcher{predicates: predicates})
       when is_list(predicates) and predicates != [] and length(predicates) <= @max_predicates do
    predicates
    |> Enum.reduce_while({:ok, []}, fn predicate, {:ok, validated} ->
      with :ok <- validate_predicate(predicate),
           false <- Enum.any?(validated, &(&1 == predicate)) do
        {:cont, {:ok, [predicate | validated]}}
      else
        _failure -> {:halt, {:error, :invalid_matcher}}
      end
    end)
    |> case do
      {:ok, _predicates} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_matcher(_matcher), do: {:error, :invalid_matcher}

  defp validate_predicate(%Predicate{field: field, operator: operator, value: value, values: []})
       when operator in [:equals, :not_equals] do
    with :ok <- validate_field(field), :ok <- validate_scalar(value), do: :ok
  end

  defp validate_predicate(%Predicate{
         field: field,
         operator: :in,
         value: nil,
         values: values
       })
       when is_list(values) and values != [] and length(values) <= @max_values do
    with :ok <- validate_field(field),
         true <- Enum.all?(values, &(validate_scalar(&1) == :ok)),
         true <- pairwise_distinct?(values) do
      :ok
    else
      _failure -> {:error, :invalid_matcher}
    end
  end

  defp validate_predicate(%Predicate{
         field: field,
         operator: :exists,
         value: nil,
         values: []
       }),
       do: validate_field(field)

  defp validate_predicate(%Predicate{field: field, operator: operator, value: value, values: []})
       when operator in [:greater_than, :less_than] and is_number(value),
       do: validate_field(field)

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

  defp validate_scalar(value) when is_nil(value) or is_boolean(value) or is_number(value), do: :ok

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

  defp validate_event_values(strings, occurred_at, observed_at) do
    if Enum.all?(strings, &(is_nil(&1) or (is_binary(&1) and String.valid?(&1)))) and
         valid_datetime?(occurred_at) and valid_optional_datetime?(observed_at) do
      :ok
    else
      {:error, :invalid_event}
    end
  end

  defp valid_optional_datetime?(nil), do: true
  defp valid_optional_datetime?(value), do: valid_datetime?(value)

  defp valid_datetime?(%DateTime{
         year: year,
         month: month,
         day: day,
         hour: hour,
         minute: minute,
         second: second,
         microsecond: {microsecond_value, precision} = microsecond,
         time_zone: time_zone,
         zone_abbr: zone_abbr,
         utc_offset: utc_offset,
         std_offset: std_offset,
         calendar: Calendar.ISO
       })
       when is_integer(year) and is_integer(month) and is_integer(day) and is_integer(hour) and
              is_integer(minute) and is_integer(second) and is_integer(microsecond_value) and
              is_integer(precision) and is_binary(time_zone) and is_binary(zone_abbr) and
              is_integer(utc_offset) and is_integer(std_offset) do
    with {:ok, _date} <- Date.new(year, month, day),
         {:ok, _time} <- Time.new(hour, minute, second, microsecond),
         true <- time_zone != "" and String.valid?(time_zone),
         true <- zone_abbr != "" and String.valid?(zone_abbr),
         true <- valid_offsets?(utc_offset, std_offset) do
      true
    else
      _failure -> false
    end
  end

  defp valid_datetime?(_value), do: false

  defp valid_offsets?(utc_offset, std_offset) do
    abs(utc_offset) < 86_400 and abs(std_offset) < 86_400 and
      abs(utc_offset + std_offset) < 86_400
  end

  defp event_scalar?(value) when is_nil(value) or is_boolean(value) or is_number(value), do: true
  defp event_scalar?(value) when is_binary(value), do: String.valid?(value)
  defp event_scalar?(_value), do: false

  defp pairwise_distinct?([]), do: true

  defp pairwise_distinct?([value | rest]) do
    not Enum.any?(rest, &(&1 == value)) and pairwise_distinct?(rest)
  end
end

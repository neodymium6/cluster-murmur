defmodule ClusterMurmur.Events.Validator do
  @moduledoc """
  Validates one bounded event without exposing its supplied values.

  Event payloads are restricted to JSON-compatible values with explicit depth,
  collection, node, string, and aggregate byte limits before matching,
  persistence, or prompt construction can inspect them.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.Event

  @max_collection_entries 256
  @max_depth 8
  @max_key_bytes 512
  @max_nodes 1_024
  @max_string_bytes 16 * 1_024
  @max_total_bytes 64 * 1_024
  @max_safe_integer 9_007_199_254_740_991
  @max_float 1.7976931348623157e308
  @storage_years 0..9999

  @type error :: :invalid_event
  @type budget :: {non_neg_integer(), non_neg_integer()}

  @doc "Validates one canonical UTC event and its bounded JSON-compatible payload."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%Event{
        id: id,
        type: type,
        source: source,
        subject: subject,
        group: group,
        severity: severity,
        previous: previous,
        current: current,
        occurred_at: occurred_at,
        observed_at: observed_at,
        dedupe_key: dedupe_key,
        correlation_key: correlation_key,
        facts: facts,
        labels: labels
      })
      when is_map(facts) and not is_struct(facts) and is_map(labels) and not is_struct(labels) do
    with {:ok, budget} <- validate_required_strings([id, type, source], {0, 0}),
         {:ok, budget} <-
           validate_optional_strings(
             [subject, group, severity, dedupe_key, correlation_key],
             budget
           ),
         :ok <- validate_datetime(occurred_at),
         :ok <- validate_optional_datetime(observed_at),
         {:ok, budget} <- validate_json(previous, 0, budget),
         {:ok, budget} <- validate_json(current, 0, budget),
         {:ok, budget} <- validate_json(facts, 0, budget),
         {:ok, _budget} <- validate_json(labels, 0, budget) do
      :ok
    else
      _failure -> {:error, :invalid_event}
    end
  rescue
    _error -> {:error, :invalid_event}
  catch
    _kind, _reason -> {:error, :invalid_event}
  end

  def validate(_event), do: {:error, :invalid_event}

  defp validate_required_strings([], budget), do: {:ok, budget}

  defp validate_required_strings([value | values], budget) do
    with {:ok, budget} <- validate_string(value, false, budget) do
      validate_required_strings(values, budget)
    end
  end

  defp validate_optional_strings([], budget), do: {:ok, budget}

  defp validate_optional_strings([nil | values], budget),
    do: validate_optional_strings(values, budget)

  defp validate_optional_strings([value | values], budget) do
    with {:ok, budget} <- validate_string(value, false, budget) do
      validate_optional_strings(values, budget)
    end
  end

  defp validate_string(value, allow_empty?, budget)
       when is_binary(value) and byte_size(value) <= @max_string_bytes do
    if String.valid?(value) and not String.contains?(value, <<0>>) and
         (allow_empty? or byte_size(value) > 0) do
      consume(budget, 1, byte_size(value))
    else
      {:error, :invalid_event}
    end
  end

  defp validate_string(_value, _allow_empty?, _budget), do: {:error, :invalid_event}

  defp validate_datetime(%DateTime{time_zone: "Etc/UTC", year: year} = datetime)
       when year in @storage_years,
       do: DateTimeValidator.validate(datetime)

  defp validate_datetime(_datetime), do: {:error, :invalid_event}

  defp validate_optional_datetime(nil), do: :ok
  defp validate_optional_datetime(datetime), do: validate_datetime(datetime)

  defp validate_json(_value, depth, _budget) when depth > @max_depth,
    do: {:error, :invalid_event}

  defp validate_json(nil, _depth, budget), do: consume(budget, 1, 0)
  defp validate_json(value, _depth, budget) when is_boolean(value), do: consume(budget, 1, 0)

  defp validate_json(value, _depth, budget)
       when is_integer(value) and value >= -@max_safe_integer and value <= @max_safe_integer,
       do: consume(budget, 1, 0)

  defp validate_json(value, _depth, budget) when is_float(value) do
    if value == value and value >= -@max_float and value <= @max_float,
      do: consume(budget, 1, 0),
      else: {:error, :invalid_event}
  end

  defp validate_json(value, _depth, budget) when is_binary(value),
    do: validate_string(value, true, budget)

  defp validate_json(%{__struct__: _module}, _depth, _budget),
    do: {:error, :invalid_event}

  defp validate_json(%{} = value, depth, budget)
       when map_size(value) <= @max_collection_entries do
    with {:ok, budget} <- consume(budget, 1, 0) do
      Enum.reduce_while(value, {:ok, budget}, fn {key, nested}, {:ok, current} ->
        with {:ok, current} <- validate_key(key, current),
             {:ok, current} <- validate_json(nested, depth + 1, current) do
          {:cont, {:ok, current}}
        else
          _failure -> {:halt, {:error, :invalid_event}}
        end
      end)
    end
  end

  defp validate_json([head | tail], depth, budget) do
    with {:ok, budget} <- consume(budget, 1, 0) do
      validate_list([head | tail], depth, budget, 0)
    end
  end

  defp validate_json([], _depth, budget), do: consume(budget, 1, 0)
  defp validate_json(_value, _depth, _budget), do: {:error, :invalid_event}

  defp validate_list([], _depth, budget, _count), do: {:ok, budget}

  defp validate_list([head | tail], depth, budget, count)
       when count < @max_collection_entries do
    with {:ok, budget} <- validate_json(head, depth + 1, budget) do
      validate_list(tail, depth, budget, count + 1)
    end
  end

  defp validate_list(_tail, _depth, _budget, _count), do: {:error, :invalid_event}

  defp validate_key(key, budget)
       when is_binary(key) and byte_size(key) <= @max_key_bytes do
    if String.valid?(key) and byte_size(key) > 0 and not String.contains?(key, <<0>>),
      do: consume(budget, 0, byte_size(key)),
      else: {:error, :invalid_event}
  end

  defp validate_key(_key, _budget), do: {:error, :invalid_event}

  defp consume({nodes, bytes}, additional_nodes, additional_bytes) do
    next_nodes = nodes + additional_nodes
    next_bytes = bytes + additional_bytes

    if next_nodes <= @max_nodes and next_bytes <= @max_total_bytes,
      do: {:ok, {next_nodes, next_bytes}},
      else: {:error, :invalid_event}
  end
end

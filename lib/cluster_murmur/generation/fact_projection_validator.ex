defmodule ClusterMurmur.Generation.FactProjectionValidator do
  @moduledoc """
  Validates one exact allowlisted generation-fact projection and converts it to
  a fixed prompt-data map.
  """

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Events.Validator, as: EventValidator
  alias ClusterMurmur.Generation.FactProjection

  @projection_keys FactProjection.__struct__() |> Map.keys()
  @projection_key_count length(@projection_keys)
  @max_collection_entries 256
  @max_depth 8
  @max_nodes 1_024
  @max_serialized_bytes 64 * 1_024

  @type error :: :invalid_fact_projection

  @doc "Validates one exact fact projection."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%FactProjection{} = projection) do
    with true <- exact_projection?(projection),
         :ok <- EventValidator.validate(synthetic_event(projection)),
         prompt <- prompt_map(projection),
         {:ok, _nodes} <- validate_tree(prompt, 0, 0),
         {:ok, size} <- json_size(prompt),
         true <- size <= @max_serialized_bytes do
      :ok
    else
      _failure -> {:error, :invalid_fact_projection}
    end
  rescue
    _error -> {:error, :invalid_fact_projection}
  catch
    _kind, _reason -> {:error, :invalid_fact_projection}
  end

  def validate(_projection), do: {:error, :invalid_fact_projection}

  @doc "Returns a fixed string-keyed prompt-data map after complete validation."
  @spec to_prompt_map(term()) :: {:ok, map()} | {:error, error()}
  def to_prompt_map(projection) do
    case validate(projection) do
      :ok -> {:ok, prompt_map(projection)}
      {:error, :invalid_fact_projection} -> {:error, :invalid_fact_projection}
    end
  end

  defp exact_projection?(projection) do
    map_size(projection) == @projection_key_count and
      Enum.all?(@projection_keys, &Map.has_key?(projection, &1))
  end

  defp synthetic_event(projection) do
    %Event{
      id: "generation-fact-projection",
      type: projection.event_type,
      source: "application",
      subject: projection.subject,
      group: projection.group,
      severity: projection.severity,
      previous: projection.previous_state,
      current: projection.current_state,
      occurred_at: projection.occurred_at,
      observed_at: nil,
      dedupe_key: nil,
      correlation_key: nil,
      facts: projection.details,
      labels: %{}
    }
  end

  defp prompt_map(projection) do
    %{
      "current_state" => projection.current_state,
      "details" => projection.details,
      "event_type" => projection.event_type,
      "group" => projection.group,
      "occurred_at" => DateTime.to_iso8601(projection.occurred_at),
      "previous_state" => projection.previous_state,
      "severity" => projection.severity,
      "subject" => projection.subject
    }
  end

  defp validate_tree(value, _depth, nodes)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_binary(value),
       do: consume_node(nodes)

  defp validate_tree(value, depth, nodes)
       when is_map(value) and not is_struct(value) and depth < @max_depth and
              map_size(value) <= @max_collection_entries do
    with {:ok, nodes} <- consume_node(nodes) do
      Enum.reduce_while(value, {:ok, nodes}, fn {_key, nested}, {:ok, current} ->
        case validate_tree(nested, depth + 1, current) do
          {:ok, current} -> {:cont, {:ok, current}}
          {:error, :invalid_fact_projection} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_tree([head | tail], depth, nodes) when depth < @max_depth do
    with {:ok, nodes} <- consume_node(nodes) do
      validate_list_tree([head | tail], depth, nodes, 0)
    end
  end

  defp validate_tree([], depth, nodes) when depth < @max_depth, do: consume_node(nodes)
  defp validate_tree(_value, _depth, _nodes), do: {:error, :invalid_fact_projection}

  defp validate_list_tree([], _depth, nodes, _count), do: {:ok, nodes}

  defp validate_list_tree([head | tail], depth, nodes, count)
       when count < @max_collection_entries do
    with {:ok, nodes} <- validate_tree(head, depth + 1, nodes) do
      validate_list_tree(tail, depth, nodes, count + 1)
    end
  end

  defp validate_list_tree(_tail, _depth, _nodes, _count),
    do: {:error, :invalid_fact_projection}

  defp consume_node(nodes) when nodes < @max_nodes, do: {:ok, nodes + 1}
  defp consume_node(_nodes), do: {:error, :invalid_fact_projection}

  defp json_size(nil), do: {:ok, 4}
  defp json_size(true), do: {:ok, 4}
  defp json_size(false), do: {:ok, 5}
  defp json_size(value) when is_integer(value), do: {:ok, byte_size(Integer.to_string(value))}

  defp json_size(value) when is_float(value),
    do: {:ok, value |> :erlang.float_to_binary([:short]) |> byte_size()}

  defp json_size(value) when is_binary(value), do: {:ok, escaped_string_size(value)}

  defp json_size(value) when is_list(value),
    do: collection_size(value, 2, 1, &json_size/1)

  defp json_size(value) when is_map(value) and not is_struct(value) do
    entries = Enum.map(value, fn {key, nested} -> {key, nested} end)

    collection_size(entries, 2, 1, fn {key, nested} ->
      with {:ok, key_size} <- json_size(key),
           {:ok, value_size} <- json_size(nested) do
        {:ok, key_size + 1 + value_size}
      end
    end)
  end

  defp json_size(_value), do: {:error, :invalid_fact_projection}

  defp collection_size(values, delimiters, separator, size_fun) do
    Enum.reduce_while(values, {:ok, delimiters, true}, fn value, {:ok, size, first?} ->
      case size_fun.(value) do
        {:ok, value_size} ->
          separator_size = if first?, do: 0, else: separator
          {:cont, {:ok, size + separator_size + value_size, false}}

        {:error, :invalid_fact_projection} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, size, _first?} -> {:ok, size}
      {:error, :invalid_fact_projection} = error -> error
    end
  end

  defp escaped_string_size(value), do: escaped_string_size(value, 2)

  defp escaped_string_size(<<>>, size), do: size

  defp escaped_string_size(<<character, rest::binary>>, size)
       when character in [?", ?\\, ?\b, ?\f, ?\n, ?\r, ?\t],
       do: escaped_string_size(rest, size + 2)

  defp escaped_string_size(<<character, rest::binary>>, size) when character < 0x20,
    do: escaped_string_size(rest, size + 6)

  defp escaped_string_size(<<character::utf8, rest::binary>>, size),
    do: escaped_string_size(rest, size + utf8_size(character))

  defp utf8_size(character) when character <= 0x7F, do: 1
  defp utf8_size(character) when character <= 0x7FF, do: 2
  defp utf8_size(character) when character <= 0xFFFF, do: 3
  defp utf8_size(_character), do: 4
end

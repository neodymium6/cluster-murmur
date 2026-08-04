defmodule ClusterMurmur.Events.BoundedJsonDecoder do
  @moduledoc false

  alias ClusterMurmur.DomainLimits

  @max_collection_entries 256
  @max_depth 8
  @max_encoded_bytes 512 * 1_024
  @max_key_bytes 512
  @max_nodes 1_024
  @max_string_bytes 16 * 1_024
  @max_total_text_bytes 64 * 1_024
  @max_safe_integer DomainLimits.max_safe_integer()
  @max_float DomainLimits.max_float()

  @type budget :: {non_neg_integer(), non_neg_integer()}
  @type error :: :invalid_json

  @spec initial_budget([term()]) :: {:ok, budget()} | {:error, error()}
  def initial_budget(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, {0, 0}}, fn
      nil, {:ok, budget} ->
        {:cont, {:ok, budget}}

      value, {:ok, budget} when is_binary(value) ->
        if valid_string?(value, false),
          do: continue_with_budget(budget, 1, byte_size(value)),
          else: {:halt, {:error, :invalid_json}}

      _invalid, _current ->
        {:halt, {:error, :invalid_json}}
    end)
  end

  def initial_budget(_values), do: {:error, :invalid_json}

  @spec consume_null(budget()) :: {:ok, nil, budget()} | {:error, error()}
  def consume_null(budget) do
    with {:ok, next_budget} <- consume(budget, 1, 0) do
      {:ok, nil, next_budget}
    end
  end

  @spec decode(term(), budget()) :: {:ok, term(), budget()} | {:error, error()}
  def decode(encoded, budget)
      when is_binary(encoded) and byte_size(encoded) <= @max_encoded_bytes do
    with {decoded, :root, <<>>} <- :json.decode(encoded, :root, decoders()),
         {:ok, value, nodes, text_bytes} <- bounded_value(decoded),
         {:ok, next_budget} <- consume(budget, nodes, text_bytes) do
      {:ok, value, next_budget}
    else
      _failure -> {:error, :invalid_json}
    end
  rescue
    _error -> {:error, :invalid_json}
  catch
    _kind, _reason -> {:error, :invalid_json}
  end

  def decode(_encoded, _budget), do: {:error, :invalid_json}

  defp decoders do
    %{
      array_start: &array_start/1,
      array_push: &array_push/2,
      array_finish: &array_finish/2,
      object_start: &object_start/1,
      object_push: &object_push/3,
      object_finish: &object_finish/2,
      integer: &integer/1,
      float: &float/1,
      string: &string/1,
      null: bounded(nil, 1, 0)
    }
  end

  defp array_start(parent) do
    {:array, [], 0, 1, 0, next_level(parent)}
  end

  defp array_push(value, {:array, values, count, nodes, text_bytes, level})
       when count < @max_collection_entries do
    with {:ok, value, value_nodes, value_text_bytes} <- bounded_value(value),
         {:ok, {next_nodes, next_text_bytes}} <-
           consume({nodes, text_bytes}, value_nodes, value_text_bytes) do
      {:array, [value | values], count + 1, next_nodes, next_text_bytes, level}
    else
      _failure -> throw(:invalid_json)
    end
  end

  defp array_push(_value, _acc), do: throw(:invalid_json)

  defp array_finish({:array, values, _count, nodes, text_bytes, _level}, old_acc) do
    {bounded(Enum.reverse(values), nodes, text_bytes), old_acc}
  end

  defp object_start(parent) do
    {:object, [], MapSet.new(), 0, 1, 0, next_level(parent)}
  end

  defp object_push(
         key,
         value,
         {:object, pairs, keys, count, nodes, text_bytes, level}
       )
       when count < @max_collection_entries do
    with {:ok, key, _key_nodes, _key_text_bytes} <- bounded_value(key),
         true <- valid_key?(key),
         false <- MapSet.member?(keys, key),
         {:ok, value, value_nodes, value_text_bytes} <- bounded_value(value),
         {:ok, {next_nodes, next_text_bytes}} <-
           consume(
             {nodes, text_bytes},
             value_nodes,
             byte_size(key) + value_text_bytes
           ) do
      {:object, [{key, value} | pairs], MapSet.put(keys, key), count + 1, next_nodes,
       next_text_bytes, level}
    else
      _failure -> throw(:invalid_json)
    end
  end

  defp object_push(_key, _value, _acc), do: throw(:invalid_json)

  defp object_finish(
         {:object, pairs, _keys, _count, nodes, text_bytes, _level},
         old_acc
       ) do
    {bounded(Map.new(pairs), nodes, text_bytes), old_acc}
  end

  defp integer(encoded) when byte_size(encoded) <= 17 do
    value = :erlang.binary_to_integer(encoded)

    if value >= -@max_safe_integer and value <= @max_safe_integer,
      do: bounded(value, 1, 0),
      else: throw(:invalid_json)
  end

  defp integer(_encoded), do: throw(:invalid_json)

  defp float(encoded) when byte_size(encoded) <= 64 do
    value = :erlang.binary_to_float(encoded)

    if value == value and value >= -@max_float and value <= @max_float,
      do: bounded(value, 1, 0),
      else: throw(:invalid_json)
  end

  defp float(_encoded), do: throw(:invalid_json)

  defp string(value) do
    if valid_string?(value, true),
      do: bounded(value, 1, byte_size(value)),
      else: throw(:invalid_json)
  end

  defp bounded(value, nodes, text_bytes),
    do: {:cluster_murmur_bounded_json, value, nodes, text_bytes}

  defp bounded_value({:cluster_murmur_bounded_json, value, nodes, text_bytes}),
    do: {:ok, value, nodes, text_bytes}

  defp bounded_value(value) when is_boolean(value), do: {:ok, value, 1, 0}
  defp bounded_value(_value), do: {:error, :invalid_json}

  defp next_level(:root), do: 1

  defp next_level({kind, _values, _count, _nodes, _text_bytes, level})
       when kind == :array and level < @max_depth,
       do: level + 1

  defp next_level({kind, _pairs, _keys, _count, _nodes, _text_bytes, level})
       when kind == :object and level < @max_depth,
       do: level + 1

  defp next_level(_parent), do: throw(:invalid_json)

  defp valid_key?(key) do
    is_binary(key) and byte_size(key) in 1..@max_key_bytes and
      String.valid?(key) and not String.contains?(key, <<0>>)
  end

  defp valid_string?(value, allow_empty?) do
    is_binary(value) and byte_size(value) <= @max_string_bytes and
      String.valid?(value) and not String.contains?(value, <<0>>) and
      (allow_empty? or byte_size(value) > 0)
  end

  defp continue_with_budget(budget, nodes, text_bytes) do
    case consume(budget, nodes, text_bytes) do
      {:ok, next_budget} -> {:cont, {:ok, next_budget}}
      {:error, :invalid_json} -> {:halt, {:error, :invalid_json}}
    end
  end

  defp consume({nodes, text_bytes}, additional_nodes, additional_text_bytes)
       when is_integer(nodes) and nodes >= 0 and is_integer(text_bytes) and text_bytes >= 0 do
    next_nodes = nodes + additional_nodes
    next_text_bytes = text_bytes + additional_text_bytes

    if next_nodes <= @max_nodes and next_text_bytes <= @max_total_text_bytes,
      do: {:ok, {next_nodes, next_text_bytes}},
      else: {:error, :invalid_json}
  end

  defp consume(_budget, _additional_nodes, _additional_text_bytes),
    do: {:error, :invalid_json}
end

defmodule ClusterMurmur.Config.DocumentDecoder do
  @moduledoc """
  Reads and decodes bounded YAML 1.2 configuration documents.

  Each input must contain exactly one document whose root is a mapping. The
  returned value uses strings for mapping keys and ordinary Elixir scalar,
  list, and map values. YAML features that can obscure or amplify input, such
  as anchors, aliases, tag directives, duplicate keys, and non-finite numbers,
  are rejected before configuration-specific validation begins.
  """

  @max_document_bytes 256 * 1_024
  @max_scalar_bytes 16 * 1_024
  @max_nodes 4_096
  @max_depth 16

  @type value :: nil | boolean() | integer() | float() | String.t() | [value()] | map()

  @type error ::
          :document_too_complex
          | :document_too_deep
          | :document_too_large
          | :duplicate_mapping_key
          | :empty_document
          | :invalid_document_path
          | :invalid_document_root
          | :invalid_mapping_key
          | :invalid_yaml
          | :multiple_documents
          | :scalar_too_large
          | :unsupported_scalar
          | :unsupported_yaml_feature
          | :unreadable_document

  @doc "Reads and decodes one configuration document without exceeding the byte limit."
  @spec decode_file(Path.t()) :: {:ok, map()} | {:error, error()}
  def decode_file(path) when is_binary(path) do
    with {:ok, contents} <- read_bounded(path) do
      decode(contents)
    end
  end

  def decode_file(_path), do: {:error, :invalid_document_path}

  @doc "Decodes one in-memory configuration document using the same limits as `decode_file/1`."
  @spec decode(binary()) :: {:ok, map()} | {:error, error()}
  def decode(contents) when is_binary(contents) do
    if byte_size(contents) <= @max_document_bytes do
      parse(contents)
    else
      {:error, :document_too_large}
    end
  end

  def decode(_contents), do: {:error, :invalid_yaml}

  defp read_bounded(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path) do
      read_regular_file(path)
    else
      _failure -> {:error, :unreadable_document}
    end
  end

  defp read_regular_file(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_document_bytes + 1)) do
      {:ok, :eof} ->
        {:ok, <<>>}

      {:ok, contents} when is_binary(contents) and byte_size(contents) <= @max_document_bytes ->
        {:ok, contents}

      {:ok, contents} when is_binary(contents) ->
        {:error, :document_too_large}

      _failure ->
        {:error, :unreadable_document}
    end
  end

  defp parse(contents) do
    options = [
      detailed_constr: true,
      keep_duplicate_keys: true,
      schema: :core,
      str_node_as_binary: true
    ]

    try do
      content_marker = :atomics.new(1, signed: false)
      constructor = :yamerl_constr.new(:cluster_murmur_config, options)
      constructor_fun = :yamerl_parser.get_token_fun(constructor)
      guarded_fun = wrap_constructor(constructor_fun, initial_state(), content_marker)
      guarded_constructor = :yamerl_parser.set_token_fun(constructor, guarded_fun)
      documents = :yamerl_constr.last_chunk(guarded_constructor, contents)

      convert_documents(documents, :atomics.get(content_marker, 1) == 1)
    catch
      :throw, {__MODULE__, reason} -> {:error, reason}
      _kind, _reason -> {:error, :invalid_yaml}
    end
  end

  defp initial_state, do: %{content?: false, depth: 0, documents: 0, nodes: 0}

  defp wrap_constructor(constructor_fun, state, content_marker) do
    fn token ->
      case token do
        :get_docs ->
          constructor_fun.(token)

        :get_constr ->
          constructor_fun.(token)

        _token ->
          state = validate_token(token, state)
          mark_content(content_marker, state)

          case constructor_fun.(token) do
            {:ok, next_fun} -> {:ok, wrap_constructor(next_fun, state, content_marker)}
            other -> other
          end
      end
    end
  end

  defp mark_content(content_marker, %{content?: true}),
    do: :atomics.put(content_marker, 1, 1)

  defp mark_content(_content_marker, _state), do: :ok

  defp validate_token({:yamerl_doc_start, _line, _column, {1, 2}, _tags}, state) do
    documents = state.documents + 1

    if documents <= 1,
      do: %{state | documents: documents},
      else: reject(:multiple_documents)
  end

  defp validate_token({:yamerl_doc_start, _line, _column, _version, _tags}, _state),
    do: reject(:unsupported_yaml_feature)

  defp validate_token({type, _line, _column, _value}, _state)
       when type in [:yamerl_anchor, :yamerl_alias],
       do: reject(:unsupported_yaml_feature)

  defp validate_token({type, _line, _column, _value, _extra}, _state)
       when type == :yamerl_tag_directive,
       do: reject(:unsupported_yaml_feature)

  defp validate_token({:yamerl_reserved_directive, _, _, _, _, _}, _state),
    do: reject(:unsupported_yaml_feature)

  defp validate_token({:yamerl_collection_start, _line, _column, tag, _style, _kind}, state) do
    validate_tag(tag)

    state
    |> Map.put(:content?, true)
    |> count_node()
    |> increase_depth()
  end

  defp validate_token({:yamerl_collection_end, _line, _column, _style, _kind}, state),
    do: %{state | depth: max(state.depth - 1, 0)}

  defp validate_token({:yamerl_scalar, _line, _column, tag, _style, substyle, text}, state) do
    validate_tag(tag)

    if text |> :unicode.characters_to_binary() |> byte_size() <= @max_scalar_bytes do
      state
      |> Map.put(
        :content?,
        state.content? or text != [] or substyle != :plain or explicitly_tagged?(tag)
      )
      |> count_node()
    else
      reject(:scalar_too_large)
    end
  end

  defp validate_token(_token, state), do: state

  defp explicitly_tagged?({:yamerl_tag, _line, _column, {:non_specific, ~c"?"}}), do: false
  defp explicitly_tagged?(_tag), do: true

  defp count_node(state) do
    nodes = state.nodes + 1

    if nodes <= @max_nodes,
      do: %{state | nodes: nodes},
      else: reject(:document_too_complex)
  end

  defp increase_depth(state) do
    depth = state.depth + 1

    if depth <= @max_depth,
      do: %{state | depth: depth},
      else: reject(:document_too_deep)
  end

  defp validate_tag({:yamerl_tag, _line, _column, {:non_specific, marker}})
       when marker in [~c"!", ~c"?"],
       do: :ok

  defp validate_tag({:yamerl_tag, _line, _column, uri})
       when uri in [
              ~c"tag:yaml.org,2002:binary",
              ~c"tag:yaml.org,2002:bool",
              ~c"tag:yaml.org,2002:float",
              ~c"tag:yaml.org,2002:int",
              ~c"tag:yaml.org,2002:map",
              ~c"tag:yaml.org,2002:null",
              ~c"tag:yaml.org,2002:seq",
              ~c"tag:yaml.org,2002:str"
            ],
       do: :ok

  defp validate_tag(_tag), do: reject(:unsupported_yaml_feature)

  defp reject(reason), do: throw({__MODULE__, reason})

  defp convert_documents(_documents, false), do: {:error, :empty_document}

  defp convert_documents([{:yamerl_doc, {:yamerl_map, _, _, _, _} = root}], true) do
    convert_map(root)
  end

  defp convert_documents([{:yamerl_doc, _root}], true), do: {:error, :invalid_document_root}
  defp convert_documents([], true), do: {:error, :empty_document}
  defp convert_documents(_documents, true), do: {:error, :multiple_documents}

  defp convert({:yamerl_map, _, _, _, _} = node), do: convert_map(node)

  defp convert({:yamerl_seq, _module, _tag, _presentation, entries, _count}) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, values} ->
      case convert(entry) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp convert({:yamerl_str, _module, _tag, _presentation, value}) when is_binary(value),
    do: {:ok, value}

  defp convert({:yamerl_null, _module, _tag, _presentation}), do: {:ok, nil}

  defp convert({:yamerl_bool, _module, _tag, _presentation, value}) when is_boolean(value),
    do: {:ok, value}

  defp convert({:yamerl_int, _module, _tag, _presentation, value}) when is_integer(value),
    do: {:ok, value}

  defp convert({:yamerl_float, _module, _tag, _presentation, value}) when is_float(value),
    do: {:ok, value}

  defp convert(_node), do: {:error, :unsupported_scalar}

  defp convert_map({:yamerl_map, _module, _tag, _presentation, pairs}) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {{:yamerl_str, _module, _tag, _presentation, key}, value}, {:ok, values}
      when is_binary(key) ->
        cond do
          Map.has_key?(values, key) ->
            {:halt, {:error, :duplicate_mapping_key}}

          true ->
            case convert(value) do
              {:ok, converted} -> {:cont, {:ok, Map.put(values, key, converted)}}
              {:error, _reason} = error -> {:halt, error}
            end
        end

      _pair, _values ->
        {:halt, {:error, :invalid_mapping_key}}
    end)
  end
end

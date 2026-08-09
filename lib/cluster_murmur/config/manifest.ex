defmodule ClusterMurmur.Config.Manifest do
  @moduledoc """
  Validates the versioned top-level configuration manifest.

  The manifest has a closed set of fields and include categories. Include
  patterns remain grouped by category for later resolution and document
  validation, while their count is bounded across the entire manifest.
  """

  @categories [
    {"event_groups", :event_groups},
    {"personas", :personas},
    {"bindings", :bindings},
    {"triggers", :triggers},
    {"routing", :routing}
  ]
  @category_names Enum.map(@categories, &elem(&1, 0))
  @required_fields ["includes", "llm", "version"]
  @fields [
    "conversation_defaults",
    "event_policy",
    "includes",
    "llm",
    "state_tracking",
    "version"
  ]
  @max_patterns 64
  @default_state_tracking ClusterMurmur.Config.StateTracking.default()
  @default_conversation_defaults ClusterMurmur.Config.ConversationDefaults.default()
  @default_event_policy ClusterMurmur.Config.EventPolicy.default()

  @derive {Inspect, only: [:version]}
  @enforce_keys [:version, :includes, :llm]
  defstruct [
    :version,
    :includes,
    :llm,
    state_tracking: @default_state_tracking,
    conversation_defaults: @default_conversation_defaults,
    event_policy: @default_event_policy
  ]

  @type category :: :event_groups | :personas | :bindings | :triggers | :routing

  @type includes :: %{
          required(:event_groups) => [String.t()],
          required(:personas) => [String.t()],
          required(:bindings) => [String.t()],
          required(:triggers) => [String.t()],
          required(:routing) => [String.t()]
        }

  @type t :: %__MODULE__{
          version: 1,
          includes: includes(),
          llm: ClusterMurmur.Config.LLM.t(),
          state_tracking: ClusterMurmur.Config.StateTracking.t(),
          conversation_defaults: ClusterMurmur.Config.ConversationDefaults.t(),
          event_policy: ClusterMurmur.Config.EventPolicy.t()
        }

  @type error ::
          :invalid_config_version
          | :invalid_include_patterns
          | :invalid_includes
          | :invalid_manifest
          | :missing_include_category
          | :missing_manifest_field
          | :too_many_include_patterns
          | :unknown_include_category
          | :unknown_manifest_field
          | :unsupported_config_version
          | {:llm, ClusterMurmur.Config.LLM.error()}
          | {:conversation_defaults, ClusterMurmur.Config.ConversationDefaults.error()}
          | {:event_policy, ClusterMurmur.Config.EventPolicy.error()}
          | {:state_tracking, ClusterMurmur.Config.StateTracking.error()}

  @doc "Validates a decoded top-level configuration document."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(document) when is_map(document) do
    with :ok <- validate_manifest_keys(document),
         {:ok, version} <- validate_version(document["version"]),
         {:ok, includes} <- validate_includes(document["includes"]),
         {:ok, llm} <- parse_llm(document["llm"]),
         {:ok, state_tracking} <- parse_state_tracking(document),
         {:ok, conversation_defaults} <- parse_conversation_defaults(document),
         {:ok, event_policy} <- parse_event_policy(document) do
      {:ok,
       %__MODULE__{
         version: version,
         includes: includes,
         llm: llm,
         state_tracking: state_tracking,
         conversation_defaults: conversation_defaults,
         event_policy: event_policy
       }}
    end
  end

  def parse(_document), do: {:error, :invalid_manifest}

  defp parse_llm(document) do
    case ClusterMurmur.Config.LLM.parse(document) do
      {:ok, llm} -> {:ok, llm}
      {:error, reason} -> {:error, {:llm, reason}}
    end
  end

  defp parse_state_tracking(document) do
    case Map.fetch(document, "state_tracking") do
      :error ->
        {:ok, ClusterMurmur.Config.StateTracking.default()}

      {:ok, value} ->
        case ClusterMurmur.Config.StateTracking.parse(value) do
          {:ok, state_tracking} -> {:ok, state_tracking}
          {:error, reason} -> {:error, {:state_tracking, reason}}
        end
    end
  end

  defp parse_conversation_defaults(document) do
    case Map.fetch(document, "conversation_defaults") do
      :error ->
        {:ok, ClusterMurmur.Config.ConversationDefaults.default()}

      {:ok, value} ->
        case ClusterMurmur.Config.ConversationDefaults.parse(value) do
          {:ok, defaults} -> {:ok, defaults}
          {:error, reason} -> {:error, {:conversation_defaults, reason}}
        end
    end
  end

  defp parse_event_policy(document) do
    case Map.fetch(document, "event_policy") do
      :error ->
        {:ok, ClusterMurmur.Config.EventPolicy.default()}

      {:ok, value} ->
        case ClusterMurmur.Config.EventPolicy.parse(value) do
          {:ok, event_policy} -> {:ok, event_policy}
          {:error, reason} -> {:error, {:event_policy, reason}}
        end
    end
  end

  defp validate_version(1), do: {:ok, 1}

  defp validate_version(version) when is_integer(version),
    do: {:error, :unsupported_config_version}

  defp validate_version(_version), do: {:error, :invalid_config_version}

  defp validate_includes(includes) when is_map(includes) do
    with :ok <- validate_keys(includes, @category_names, :includes) do
      collect_categories(@categories, includes, %{}, 0)
    end
  end

  defp validate_includes(_includes), do: {:error, :invalid_includes}

  defp validate_manifest_keys(map) do
    cond do
      Enum.any?(@required_fields, &(not Map.has_key?(map, &1))) ->
        {:error, :missing_manifest_field}

      map_size(map) > length(@fields) or Enum.any?(Map.keys(map), &(&1 not in @fields)) ->
        {:error, :unknown_manifest_field}

      true ->
        :ok
    end
  end

  defp validate_keys(map, required_keys, scope) do
    cond do
      Enum.any?(required_keys, &(not Map.has_key?(map, &1))) ->
        missing_key_error(scope)

      map_size(map) != length(required_keys) ->
        unknown_key_error(scope)

      true ->
        :ok
    end
  end

  defp missing_key_error(:includes), do: {:error, :missing_include_category}
  defp unknown_key_error(:includes), do: {:error, :unknown_include_category}

  defp collect_categories([], _source, includes, _count), do: {:ok, includes}

  defp collect_categories([{name, category} | remaining], source, includes, count) do
    with {:ok, patterns, count} <- collect_patterns(source[name], count, []) do
      collect_categories(remaining, source, Map.put(includes, category, patterns), count)
    end
  end

  defp collect_patterns([], count, patterns), do: {:ok, Enum.reverse(patterns), count}

  defp collect_patterns([pattern | remaining], count, patterns) when is_binary(pattern) do
    if count < @max_patterns do
      collect_patterns(remaining, count + 1, [pattern | patterns])
    else
      {:error, :too_many_include_patterns}
    end
  end

  defp collect_patterns(_patterns, _count, _accumulator),
    do: {:error, :invalid_include_patterns}
end

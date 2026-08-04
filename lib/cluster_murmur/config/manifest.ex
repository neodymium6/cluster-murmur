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
  @fields ["includes", "version"]
  @max_patterns 64

  @enforce_keys [:version, :includes]
  defstruct [:version, :includes]

  @type category :: :event_groups | :personas | :bindings | :triggers | :routing
  @type includes :: %{required(category()) => [String.t()]}
  @type t :: %__MODULE__{version: 1, includes: includes()}

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

  @doc "Validates a decoded top-level configuration document."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(document) when is_map(document) do
    with :ok <- validate_keys(document, @fields, :manifest),
         {:ok, version} <- validate_version(document["version"]),
         {:ok, includes} <- validate_includes(document["includes"]) do
      {:ok, %__MODULE__{version: version, includes: includes}}
    end
  end

  def parse(_document), do: {:error, :invalid_manifest}

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

  defp validate_keys(map, required_keys, scope) do
    keys = Map.keys(map)

    cond do
      Enum.any?(required_keys, &(not Map.has_key?(map, &1))) ->
        missing_key_error(scope)

      Enum.any?(keys, &(&1 not in required_keys)) ->
        unknown_key_error(scope)

      true ->
        :ok
    end
  end

  defp missing_key_error(:manifest), do: {:error, :missing_manifest_field}
  defp missing_key_error(:includes), do: {:error, :missing_include_category}
  defp unknown_key_error(:manifest), do: {:error, :unknown_manifest_field}
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

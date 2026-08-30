defmodule ClusterMurmur.Config.ExternalIngestion do
  @moduledoc """
  Validates the source-scoped allowlist for normalized external events.

  An empty source map disables the boundary. The configuration contains no
  listener, credential, endpoint, or caller-selected execution capability.
  """

  alias ClusterMurmur.Config.Value

  defmodule Source do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:event_types, :groups, :subjects, :fact_keys, :label_keys]
    defstruct [:event_types, :groups, :subjects, :fact_keys, :label_keys]

    @type t :: %__MODULE__{
            event_types: MapSet.t(String.t()),
            groups: MapSet.t(String.t()),
            subjects: MapSet.t(String.t()),
            fact_keys: MapSet.t(String.t()),
            label_keys: MapSet.t(String.t())
          }
  end

  @document_keys ["sources"]
  @source_document_keys ["event_types", "groups", "subjects", "fact_keys", "label_keys"]
  @struct_keys [:__struct__, :sources]
  @source_struct_keys Source.__struct__() |> Map.keys()
  @max_sources 32
  @max_values 256
  @max_value_bytes 256

  @derive {Inspect, only: []}
  @enforce_keys [:sources]
  defstruct [:sources]

  @type t :: %__MODULE__{sources: %{optional(String.t()) => Source.t()}}
  @type error :: :invalid_external_ingestion_configuration

  @doc "Returns the disabled external-ingestion configuration."
  @spec default() :: t()
  def default, do: %__MODULE__{sources: %{}}

  @doc "Parses one exact external-ingestion mapping."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(document) when is_map(document) and not is_struct(document) do
    with true <- exact_map?(document, @document_keys),
         {:ok, sources} <- parse_sources(document["sources"]),
         candidate = %__MODULE__{sources: sources},
         :ok <- validate(candidate) do
      {:ok, candidate}
    else
      _failure -> {:error, :invalid_external_ingestion_configuration}
    end
  rescue
    _error -> {:error, :invalid_external_ingestion_configuration}
  catch
    _kind, _reason -> {:error, :invalid_external_ingestion_configuration}
  end

  def parse(_document), do: {:error, :invalid_external_ingestion_configuration}

  @doc "Revalidates one exact normalized external-ingestion configuration."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{sources: sources} = configuration) do
    if exact_map?(configuration, @struct_keys) and valid_sources?(sources),
      do: :ok,
      else: {:error, :invalid_external_ingestion_configuration}
  rescue
    _error -> {:error, :invalid_external_ingestion_configuration}
  catch
    _kind, _reason -> {:error, :invalid_external_ingestion_configuration}
  end

  def validate(_configuration), do: {:error, :invalid_external_ingestion_configuration}

  @doc false
  @spec to_document(term()) :: {:ok, map()} | {:error, error()}
  def to_document(%__MODULE__{} = configuration) do
    case validate(configuration) do
      :ok ->
        sources =
          configuration.sources
          |> Enum.sort_by(&elem(&1, 0))
          |> Map.new(fn {source, policy} ->
            {source,
             %{
               "event_types" => sorted(policy.event_types),
               "groups" => sorted(policy.groups),
               "subjects" => sorted(policy.subjects),
               "fact_keys" => sorted(policy.fact_keys),
               "label_keys" => sorted(policy.label_keys)
             }}
          end)

        {:ok, %{"sources" => sources}}

      {:error, :invalid_external_ingestion_configuration} = error ->
        error
    end
  end

  def to_document(_configuration), do: {:error, :invalid_external_ingestion_configuration}

  defp parse_sources(sources)
       when is_map(sources) and not is_struct(sources) and map_size(sources) <= @max_sources do
    Enum.reduce_while(sources, {:ok, %{}}, fn {source, document}, {:ok, parsed} ->
      with true <- valid_value?(source),
           {:ok, policy} <- parse_source(document) do
        {:cont, {:ok, Map.put(parsed, source, policy)}}
      else
        _failure -> {:halt, {:error, :invalid_external_ingestion_configuration}}
      end
    end)
  end

  defp parse_sources(_sources), do: {:error, :invalid_external_ingestion_configuration}

  defp parse_source(document) when is_map(document) and not is_struct(document) do
    with true <- exact_map?(document, @source_document_keys),
         {:ok, event_types} <- parse_values(document["event_types"], false),
         {:ok, groups} <- parse_values(document["groups"], false),
         {:ok, subjects} <- parse_values(document["subjects"], false),
         {:ok, fact_keys} <- parse_values(document["fact_keys"], true),
         {:ok, label_keys} <- parse_values(document["label_keys"], true) do
      {:ok,
       %Source{
         event_types: event_types,
         groups: groups,
         subjects: subjects,
         fact_keys: fact_keys,
         label_keys: label_keys
       }}
    else
      _failure -> {:error, :invalid_external_ingestion_configuration}
    end
  end

  defp parse_source(_document), do: {:error, :invalid_external_ingestion_configuration}

  defp parse_values(values, allow_empty?)
       when is_list(values) and length(values) <= @max_values do
    set = MapSet.new(values)

    if Enum.all?(values, &valid_value?/1) and MapSet.size(set) == length(values) and
         (allow_empty? or MapSet.size(set) > 0),
       do: {:ok, set},
       else: {:error, :invalid_external_ingestion_configuration}
  end

  defp parse_values(_values, _allow_empty?),
    do: {:error, :invalid_external_ingestion_configuration}

  defp valid_sources?(sources)
       when is_map(sources) and not is_struct(sources) and map_size(sources) <= @max_sources do
    Enum.all?(sources, fn {source, policy} -> valid_value?(source) and valid_source?(policy) end)
  end

  defp valid_sources?(_sources), do: false

  defp valid_source?(%Source{} = source) do
    exact_map?(source, @source_struct_keys) and
      valid_set?(source.event_types, false) and valid_set?(source.groups, false) and
      valid_set?(source.subjects, false) and valid_set?(source.fact_keys, true) and
      valid_set?(source.label_keys, true)
  end

  defp valid_source?(_source), do: false

  defp valid_set?(%MapSet{} = values, allow_empty?) do
    MapSet.size(values) <= @max_values and Enum.all?(values, &valid_value?/1) and
      (allow_empty? or MapSet.size(values) > 0)
  end

  defp valid_set?(_values, _allow_empty?), do: false

  defp valid_value?(value) when is_binary(value) and byte_size(value) <= @max_value_bytes,
    do: match?({:ok, ^value}, Value.id(value))

  defp valid_value?(_value), do: false

  defp sorted(values), do: values |> MapSet.to_list() |> Enum.sort()

  defp exact_map?(value, keys),
    do: map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))
end

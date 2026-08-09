defmodule ClusterMurmur.Config.StateTracking do
  @moduledoc """
  Validates version 1 observation debounce settings.

  Public failure and success counts plus bounded source and source-subject
  overrides are normalized without reading an observer or durable state. The
  resulting value can project only the fixed `DebouncePolicy` consumed by
  application-owned ingestion decisions.
  """

  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Observations.DebouncePolicy

  @required_document_keys ["failures_required", "successes_required"]
  @document_keys ["failures_required", "successes_required", "overrides"]
  @struct_keys [:__struct__, :failures_required, :successes_required, :overrides]
  @struct_key_count length(@struct_keys)
  @max_overrides 256
  @max_selector_bytes DomainLimits.max_id_bytes()
  @max_threshold DomainLimits.max_safe_integer()
  @default_threshold 2

  @derive {Inspect, only: [:failures_required, :successes_required]}
  @enforce_keys [:failures_required, :successes_required]
  defstruct [:failures_required, :successes_required, overrides: %{}]

  defmodule Override do
    @moduledoc false

    @derive {Inspect, only: [:failures_required, :successes_required]}
    @enforce_keys [:source, :subject, :failures_required, :successes_required]
    defstruct [:source, :subject, :failures_required, :successes_required]

    @type t :: %__MODULE__{
            source: String.t(),
            subject: String.t() | nil,
            failures_required: pos_integer(),
            successes_required: pos_integer()
          }
  end

  @type t :: %__MODULE__{
          failures_required: pos_integer(),
          successes_required: pos_integer(),
          overrides: %{
            optional({String.t(), String.t() | nil}) => Override.t()
          }
        }

  @type error :: :invalid_state_tracking_configuration

  @doc "Returns the fixed version 1 default debounce settings."
  @spec default() :: t()
  def default do
    %__MODULE__{
      failures_required: @default_threshold,
      successes_required: @default_threshold,
      overrides: %{}
    }
  end

  @doc "Parses one exact decoded version 1 state-tracking mapping."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(document) when is_map(document) and not is_struct(document) do
    with true <- exact_document?(document),
         true <- valid_threshold?(document["failures_required"]),
         true <- valid_threshold?(document["successes_required"]),
         {:ok, overrides} <- parse_overrides(Map.get(document, "overrides", [])) do
      {:ok,
       %__MODULE__{
         failures_required: document["failures_required"],
         successes_required: document["successes_required"],
         overrides: overrides
       }}
    else
      _failure -> {:error, :invalid_state_tracking_configuration}
    end
  rescue
    _error -> {:error, :invalid_state_tracking_configuration}
  catch
    _kind, _reason -> {:error, :invalid_state_tracking_configuration}
  end

  def parse(_document), do: {:error, :invalid_state_tracking_configuration}

  @doc "Revalidates one exact normalized state-tracking value."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{} = state_tracking) do
    if exact_struct?(state_tracking) and valid_threshold?(state_tracking.failures_required) and
         valid_threshold?(state_tracking.successes_required) and
         valid_overrides?(state_tracking.overrides),
       do: :ok,
       else: {:error, :invalid_state_tracking_configuration}
  rescue
    _error -> {:error, :invalid_state_tracking_configuration}
  catch
    _kind, _reason -> {:error, :invalid_state_tracking_configuration}
  end

  def validate(_state_tracking), do: {:error, :invalid_state_tracking_configuration}

  @doc "Projects the only debounce policy accepted by observation ingestion."
  @spec to_debounce_policy(term()) :: {:ok, DebouncePolicy.t()} | {:error, error()}
  def to_debounce_policy(state_tracking) do
    case validate(state_tracking) do
      :ok ->
        {:ok, policy(state_tracking.failures_required, state_tracking.successes_required)}

      {:error, :invalid_state_tracking_configuration} = error ->
        error
    end
  end

  @doc "Resolves exact source-subject, then source, then default debounce settings."
  @spec resolve(term(), term(), term()) :: {:ok, DebouncePolicy.t()} | {:error, error()}
  def resolve(state_tracking, source, subject) do
    with :ok <- validate(state_tracking),
         true <- valid_selector?(source),
         true <- valid_selector?(subject) do
      override =
        Map.get(state_tracking.overrides, {source, subject}) ||
          Map.get(state_tracking.overrides, {source, nil})

      case override do
        %Override{} ->
          {:ok, policy(override.failures_required, override.successes_required)}

        nil ->
          to_debounce_policy(state_tracking)
      end
    else
      _failure -> {:error, :invalid_state_tracking_configuration}
    end
  rescue
    _error -> {:error, :invalid_state_tracking_configuration}
  catch
    _kind, _reason -> {:error, :invalid_state_tracking_configuration}
  end

  @doc false
  @spec to_document(term()) :: {:ok, map()} | {:error, error()}
  def to_document(state_tracking) do
    case validate(state_tracking) do
      :ok ->
        document = %{
          "failures_required" => state_tracking.failures_required,
          "successes_required" => state_tracking.successes_required
        }

        if map_size(state_tracking.overrides) == 0,
          do: {:ok, document},
          else: {:ok, Map.put(document, "overrides", overrides_to_document(state_tracking))}

      {:error, :invalid_state_tracking_configuration} = error ->
        error
    end
  end

  defp exact_document?(document) do
    map_size(document) in 2..3 and
      Enum.all?(@required_document_keys, &Map.has_key?(document, &1)) and
      Enum.all?(Map.keys(document), &(&1 in @document_keys))
  end

  defp exact_struct?(state_tracking) do
    map_size(state_tracking) == @struct_key_count and
      Enum.all?(@struct_keys, &Map.has_key?(state_tracking, &1))
  end

  defp valid_threshold?(value),
    do: is_integer(value) and value in 1..@max_threshold

  defp parse_overrides(overrides) when is_list(overrides),
    do: parse_overrides(overrides, %{}, 0)

  defp parse_overrides(_overrides), do: {:error, :invalid_state_tracking_configuration}

  defp parse_overrides([], parsed, _count), do: {:ok, parsed}

  defp parse_overrides([attributes | rest], parsed, count) when count < @max_overrides do
    with {:ok, override} <- parse_override(attributes),
         key = {override.source, override.subject},
         false <- Map.has_key?(parsed, key) do
      parse_overrides(rest, Map.put(parsed, key, override), count + 1)
    else
      _failure -> {:error, :invalid_state_tracking_configuration}
    end
  end

  defp parse_overrides(_overrides, _parsed, _count),
    do: {:error, :invalid_state_tracking_configuration}

  defp parse_override(attributes) when is_map(attributes) and not is_struct(attributes) do
    required = ["source", "failures_required", "successes_required"]
    allowed = ["source", "subject", "failures_required", "successes_required"]

    with true <- map_size(attributes) in 3..4,
         true <- Enum.all?(required, &Map.has_key?(attributes, &1)),
         true <- Enum.all?(Map.keys(attributes), &(&1 in allowed)),
         true <- valid_selector?(attributes["source"]),
         subject = Map.get(attributes, "subject"),
         true <- is_nil(subject) or valid_selector?(subject),
         true <- valid_threshold?(attributes["failures_required"]),
         true <- valid_threshold?(attributes["successes_required"]) do
      {:ok,
       %Override{
         source: attributes["source"],
         subject: subject,
         failures_required: attributes["failures_required"],
         successes_required: attributes["successes_required"]
       }}
    else
      _failure -> {:error, :invalid_state_tracking_configuration}
    end
  end

  defp parse_override(_attributes), do: {:error, :invalid_state_tracking_configuration}

  defp valid_overrides?(overrides)
       when is_map(overrides) and not is_struct(overrides) and
              map_size(overrides) <= @max_overrides do
    Enum.all?(overrides, fn
      {{source, subject}, %Override{} = override} ->
        exact_override?(override) and override.source == source and override.subject == subject and
          valid_selector?(source) and (is_nil(subject) or valid_selector?(subject)) and
          valid_threshold?(override.failures_required) and
          valid_threshold?(override.successes_required)

      _invalid ->
        false
    end)
  end

  defp valid_overrides?(_overrides), do: false

  defp exact_override?(override) do
    keys = Override.__struct__() |> Map.keys()
    map_size(override) == length(keys) and Enum.all?(keys, &Map.has_key?(override, &1))
  end

  defp valid_selector?(value)
       when is_binary(value) and byte_size(value) in 1..@max_selector_bytes do
    String.valid?(value) and not String.contains?(value, <<0>>)
  end

  defp valid_selector?(_value), do: false

  defp policy(failures_required, successes_required) do
    %DebouncePolicy{
      healthy_threshold: successes_required,
      unhealthy_threshold: failures_required
    }
  end

  defp overrides_to_document(state_tracking) do
    state_tracking.overrides
    |> Map.values()
    |> Enum.sort_by(&{&1.source, &1.subject || ""})
    |> Enum.map(fn override ->
      document = %{
        "source" => override.source,
        "failures_required" => override.failures_required,
        "successes_required" => override.successes_required
      }

      if is_nil(override.subject),
        do: document,
        else: Map.put(document, "subject", override.subject)
    end)
  end
end

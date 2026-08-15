defmodule ClusterMurmur.Config.Presentation do
  @moduledoc """
  Validates the deployment-wide presentation settings used for generated facts.

  Presentation changes prompt-facing representations only. Canonical event
  timestamps, persistence, ordering, and identity remain in UTC.
  """

  @document_keys ["timezone"]
  @struct_keys [:__struct__, :timezone]
  @max_timezone_bytes 128

  @derive {Inspect, only: []}
  @enforce_keys [:timezone]
  defstruct [:timezone]

  @type t :: %__MODULE__{timezone: Calendar.time_zone()}
  @type error :: :invalid_presentation_configuration

  @doc "Returns the backwards-compatible UTC presentation settings."
  @spec default() :: t()
  def default, do: %__MODULE__{timezone: "Etc/UTC"}

  @doc "Parses one exact decoded version 1 presentation mapping."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(document) when is_map(document) and not is_struct(document) do
    candidate = %__MODULE__{timezone: document["timezone"]}

    if exact_map?(document, @document_keys) and validate(candidate) == :ok,
      do: {:ok, candidate},
      else: {:error, :invalid_presentation_configuration}
  rescue
    _error -> {:error, :invalid_presentation_configuration}
  catch
    _kind, _reason -> {:error, :invalid_presentation_configuration}
  end

  def parse(_document), do: {:error, :invalid_presentation_configuration}

  @doc "Revalidates one exact normalized presentation value."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{timezone: timezone} = presentation) do
    if exact_map?(presentation, @struct_keys) and valid_timezone?(timezone),
      do: :ok,
      else: {:error, :invalid_presentation_configuration}
  rescue
    _error -> {:error, :invalid_presentation_configuration}
  catch
    _kind, _reason -> {:error, :invalid_presentation_configuration}
  end

  def validate(_presentation), do: {:error, :invalid_presentation_configuration}

  @doc false
  @spec to_document(term()) :: {:ok, map()} | {:error, error()}
  def to_document(presentation) do
    case validate(presentation) do
      :ok -> {:ok, %{"timezone" => presentation.timezone}}
      {:error, :invalid_presentation_configuration} = error -> error
    end
  end

  defp valid_timezone?(timezone)
       when is_binary(timezone) and byte_size(timezone) in 1..@max_timezone_bytes do
    String.valid?(timezone) and timezone in TimeZoneInfo.time_zones()
  end

  defp valid_timezone?(_timezone), do: false

  defp exact_map?(value, keys),
    do: map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))
end

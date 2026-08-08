defmodule ClusterMurmur.Observers.Client do
  @moduledoc """
  Boundary for a normalized, read-only observation source.

  A client value pairs one adapter with its opaque injected context. Concrete
  adapters map these named operations to their transport internally.
  No transport tool name, arbitrary argument map, or raw response crosses this
  boundary. Application code normalizes the returned target maps through the
  bounded target catalog before calling `observe_target/2`.
  """

  alias ClusterMurmur.ExternalError
  alias ClusterMurmur.Observations.Observation

  @derive {Inspect, only: [:adapter]}
  @enforce_keys [:adapter, :context]
  defstruct [:adapter, :context]

  @client_keys [:__struct__, :adapter, :context]
  @client_key_count length(@client_keys)

  @type target :: %{required(:id) => String.t()}
  @type t :: %__MODULE__{adapter: module(), context: term()}

  @callback list_targets(term()) :: {:ok, [target()]} | {:error, ExternalError.t()}
  @callback observe_target(term(), String.t()) ::
              {:ok, Observation.t()} | {:error, ExternalError.t()}

  @doc "Builds one redacted client capability from an adapter and its context."
  @spec new(term(), term()) :: {:ok, t()} | {:error, :invalid_observer_client}
  def new(adapter, context) when is_atom(adapter) do
    client = %__MODULE__{adapter: adapter, context: context}

    case validate(client) do
      :ok -> {:ok, client}
      {:error, :invalid_observer_client} = error -> error
    end
  end

  def new(_adapter, _context), do: {:error, :invalid_observer_client}

  @doc "Revalidates the exact adapter surface without inspecting its context."
  @spec validate(term()) :: :ok | {:error, :invalid_observer_client}
  def validate(%__MODULE__{} = client) do
    if map_size(client) == @client_key_count and
         Enum.all?(@client_keys, &Map.has_key?(client, &1)) and
         is_atom(client.adapter) and Code.ensure_loaded?(client.adapter) and
         function_exported?(client.adapter, :list_targets, 1) and
         function_exported?(client.adapter, :observe_target, 2),
       do: :ok,
       else: {:error, :invalid_observer_client}
  rescue
    _error -> {:error, :invalid_observer_client}
  catch
    _kind, _reason -> {:error, :invalid_observer_client}
  end

  def validate(_client), do: {:error, :invalid_observer_client}
end

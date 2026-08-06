defmodule ClusterMurmur.Observers.Target do
  @moduledoc """
  One exact redacted identity returned by a read-only observer.

  Target IDs select only the named `observe_target/1` operation. They never
  carry transport tool names, arbitrary arguments, endpoints, or credentials.
  """

  alias ClusterMurmur.Config.Value

  @target_keys [:__struct__, :id]
  @target_key_count length(@target_keys)

  @derive {Inspect, only: []}
  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: String.t()}
  @type error :: :invalid_observer_target

  @doc "Normalizes one exact target map returned by an observer adapter."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(%{id: id} = target) when map_size(target) == 1 and not is_struct(target) do
    case Value.id(id) do
      {:ok, ^id} -> {:ok, %__MODULE__{id: id}}
      {:error, :invalid_id} -> {:error, :invalid_observer_target}
    end
  rescue
    _error -> {:error, :invalid_observer_target}
  catch
    _kind, _reason -> {:error, :invalid_observer_target}
  end

  def parse(_target), do: {:error, :invalid_observer_target}

  @doc "Revalidates one exact normalized observer target."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{} = target) do
    if map_size(target) == @target_key_count and
         Enum.all?(@target_keys, &Map.has_key?(target, &1)) and
         match?({:ok, _id}, Value.id(target.id)),
       do: :ok,
       else: {:error, :invalid_observer_target}
  rescue
    _error -> {:error, :invalid_observer_target}
  catch
    _kind, _reason -> {:error, :invalid_observer_target}
  end

  def validate(_target), do: {:error, :invalid_observer_target}
end

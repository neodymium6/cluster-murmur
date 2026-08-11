defmodule ClusterMurmur.Runtime.PersonaCooldownSnapshot do
  @moduledoc """
  Restores one bounded current cooldown snapshot for configured personas.

  The loader validates the complete configuration and narrow store before its
  first read, fetches each configured persona exactly once in stable order, and
  returns only validated loaded cooldown records. It does not list arbitrary
  persistence rows, read a clock, select a speaker, or mutate cooldown state.
  """

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Persistence.{PersonaCooldownRecord, PersonaCooldownStore}
  alias ClusterMurmur.Personas.StarterCandidateProjector

  @type snapshot :: %{optional(String.t()) => PersonaCooldownRecord.t()}
  @type error :: :invalid_persona_cooldown_snapshot | :persona_cooldown_snapshot_failed

  @doc "Restores current cooldowns for every configured persona in stable order."
  @spec load(term(), module()) :: {:ok, snapshot()} | {:error, error()}
  def load(configuration, store \\ PersonaCooldownStore)

  def load(%Configuration{} = configuration, store) when is_atom(store) do
    with :ok <- validate_inputs(configuration, store),
         {:ok, snapshot} <- restore(configuration, store),
         :ok <- validate(snapshot, configuration) do
      {:ok, snapshot}
    else
      {:error, :invalid_persona_cooldown_snapshot} = error -> error
      _failure -> {:error, :persona_cooldown_snapshot_failed}
    end
  rescue
    _error -> {:error, :persona_cooldown_snapshot_failed}
  catch
    _kind, _reason -> {:error, :persona_cooldown_snapshot_failed}
  end

  def load(_configuration, _store), do: {:error, :invalid_persona_cooldown_snapshot}

  @doc "Revalidates a snapshot against the exact current persona catalog."
  @spec validate(term(), term()) :: :ok | {:error, :invalid_persona_cooldown_snapshot}
  def validate(snapshot, %Configuration{} = configuration) do
    configured_ids = configuration.personas.personas |> Map.keys() |> MapSet.new()

    if Configuration.validate(configuration) == :ok and
         StarterCandidateProjector.validate_cooldowns(snapshot) == :ok and
         Enum.all?(Map.keys(snapshot), &MapSet.member?(configured_ids, &1)) do
      :ok
    else
      {:error, :invalid_persona_cooldown_snapshot}
    end
  rescue
    _error -> {:error, :invalid_persona_cooldown_snapshot}
  catch
    _kind, _reason -> {:error, :invalid_persona_cooldown_snapshot}
  end

  def validate(_snapshot, _configuration), do: {:error, :invalid_persona_cooldown_snapshot}

  defp validate_inputs(configuration, store) do
    if Configuration.validate(configuration) == :ok and Code.ensure_loaded?(store) and
         function_exported?(store, :fetch, 1),
       do: :ok,
       else: {:error, :invalid_persona_cooldown_snapshot}
  end

  defp restore(configuration, store) do
    configuration.personas.personas
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn persona_id, {:ok, snapshot} ->
      case store.fetch(persona_id) do
        {:ok, nil} ->
          {:cont, {:ok, snapshot}}

        {:ok, %PersonaCooldownRecord{persona_id: ^persona_id} = record} ->
          candidate = Map.put(snapshot, persona_id, record)

          case StarterCandidateProjector.validate_cooldowns(candidate) do
            :ok -> {:cont, {:ok, candidate}}
            {:error, _reason} -> {:halt, {:error, :persona_cooldown_snapshot_failed}}
          end

        _failure ->
          {:halt, {:error, :persona_cooldown_snapshot_failed}}
      end
    end)
  end
end

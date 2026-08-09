defmodule ClusterMurmur.Events.RetentionPlanner do
  @moduledoc """
  Purely derives one bounded event-retention cutoff.

  The caller supplies the complete normalized event policy and one injected
  UTC instant. The resulting plan retains their exact correlation for later
  persistence boundaries without reading a clock or deleting stored data.
  """

  alias ClusterMurmur.Config.EventPolicy
  alias ClusterMurmur.DateTimeValidator

  defmodule Plan do
    @moduledoc false

    @derive {Inspect, only: [:policy, :planned_at, :cutoff]}
    @enforce_keys [:policy, :planned_at, :cutoff]
    defstruct [:policy, :planned_at, :cutoff]

    @type t :: %__MODULE__{
            policy: EventPolicy.t(),
            planned_at: DateTime.t(),
            cutoff: DateTime.t()
          }
  end

  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)

  @type error ::
          :invalid_datetime
          | :invalid_event_policy
          | :invalid_retention_plan
          | :no_retention_cutoff

  @doc "Builds one exact retention plan from validated policy and time facts."
  @spec plan(term(), term()) :: {:ok, Plan.t()} | {:error, error()}
  def plan(policy, planned_at) do
    with :ok <- EventPolicy.validate(policy),
         :ok <- DateTimeValidator.validate_storage_utc(planned_at),
         {:ok, cutoff} <- retention_cutoff(planned_at, policy.retention_ms) do
      {:ok, %Plan{policy: policy, planned_at: planned_at, cutoff: cutoff}}
    else
      {:error, reason}
      when reason in [:invalid_datetime, :invalid_event_policy, :no_retention_cutoff] ->
        {:error, reason}

      _failure ->
        {:error, :invalid_retention_plan}
    end
  rescue
    _error -> {:error, :invalid_retention_plan}
  catch
    _kind, _reason -> {:error, :invalid_retention_plan}
  end

  @doc "Revalidates an exact plan and its policy/time correlation."
  @spec validate(term()) :: :ok | {:error, :invalid_retention_plan}
  def validate(%Plan{} = plan) do
    with true <- exact_plan?(plan),
         :ok <- EventPolicy.validate(plan.policy),
         :ok <- DateTimeValidator.validate_storage_utc(plan.planned_at),
         :ok <- DateTimeValidator.validate_storage_utc(plan.cutoff),
         {:ok, expected_cutoff} <- retention_cutoff(plan.planned_at, plan.policy.retention_ms),
         true <- plan.cutoff === expected_cutoff do
      :ok
    else
      _failure -> {:error, :invalid_retention_plan}
    end
  rescue
    _error -> {:error, :invalid_retention_plan}
  catch
    _kind, _reason -> {:error, :invalid_retention_plan}
  end

  def validate(_plan), do: {:error, :invalid_retention_plan}

  defp retention_cutoff(planned_at, retention_ms) do
    cutoff = DateTime.add(planned_at, -retention_ms, :millisecond)

    case DateTimeValidator.validate_storage_utc(cutoff) do
      :ok -> {:ok, cutoff}
      {:error, :invalid_datetime} -> {:error, :no_retention_cutoff}
    end
  rescue
    _error -> {:error, :no_retention_cutoff}
  catch
    _kind, _reason -> {:error, :no_retention_cutoff}
  end

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end
end

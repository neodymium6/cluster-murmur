defmodule ClusterMurmur.Persistence.TriggerExecution do
  @moduledoc """
  Redacted durable state for one event-trigger and event pair.

  New records can only be constructed from a complete, revalidated execution
  plan. Terminal lifecycle transitions remain a later store concern.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Events.{MatcherEvaluator, Validator}
  alias ClusterMurmur.Triggers.EventTriggerValidator
  alias ClusterMurmur.Triggers.EventTriggerExecutionPlanner.Plan

  @derive {Inspect, only: []}
  @primary_key false
  @plan_keys Plan.__struct__() |> Map.keys()
  @plan_key_count length(@plan_keys)
  @fields [:trigger_id, :event_id, :status, :executed_at, :cooldown_until, :error_class]

  schema "trigger_executions" do
    field :trigger_id, :string, primary_key: true, redact: true
    field :event_id, :string, primary_key: true, redact: true
    field :status, Ecto.Enum, values: [:started, :completed, :failed], redact: true
    field :executed_at, :utc_datetime_usec, redact: true
    field :cooldown_until, :utc_datetime_usec, redact: true
    field :error_class, :string, redact: true
  end

  @type status :: :started | :completed | :failed
  @type t :: %__MODULE__{
          trigger_id: String.t() | nil,
          event_id: String.t() | nil,
          status: status() | nil,
          executed_at: DateTime.t() | nil,
          cooldown_until: DateTime.t() | nil,
          error_class: String.t() | nil
        }

  @doc "Builds a redacted started record from one complete event-trigger execution plan."
  @spec start_changeset(t(), term()) :: Ecto.Changeset.t()
  def start_changeset(%__MODULE__{} = execution, %Plan{} = plan) do
    if pristine_execution?(execution) and valid_plan?(plan) do
      execution
      |> cast(
        %{
          trigger_id: plan.trigger.id,
          event_id: plan.event.id,
          status: :started,
          executed_at: plan.executed_at,
          cooldown_until: plan.cooldown_until,
          error_class: nil
        },
        @fields
      )
      |> validate_required([:trigger_id, :event_id, :status, :executed_at, :cooldown_until])
      |> check_constraints()
    else
      invalid_changeset(execution)
    end
  rescue
    _error -> invalid_changeset(execution)
  catch
    _kind, _reason -> invalid_changeset(execution)
  end

  def start_changeset(%__MODULE__{} = execution, _plan), do: invalid_changeset(execution)

  defp pristine_execution?(execution), do: execution == %__MODULE__{}

  defp valid_plan?(plan) do
    exact_plan?(plan) and
      EventTriggerValidator.validate(plan.trigger) == :ok and
      Validator.validate(plan.event) == :ok and
      MatcherEvaluator.match(plan.trigger.matcher, plan.event) == {:ok, true} and
      valid_datetime?(plan.executed_at) and
      valid_datetime?(plan.cooldown_until) and
      expected_cooldown?(plan)
  end

  defp exact_plan?(plan) do
    map_size(plan) == @plan_key_count and Enum.all?(@plan_keys, &Map.has_key?(plan, &1))
  end

  defp expected_cooldown?(plan) do
    plan.executed_at
    |> DateTime.add(plan.trigger.cooldown_ms * 1_000, :microsecond)
    |> DateTime.compare(plan.cooldown_until) == :eq
  end

  defp valid_datetime?(datetime),
    do: DateTimeValidator.validate_storage_utc(datetime) == :ok

  defp check_constraints(changeset) do
    changeset
    |> check_constraint(:trigger_id, name: "trigger_executions_trigger_id")
    |> check_constraint(:event_id, name: "trigger_executions_event_id")
    |> check_constraint(:status, name: "trigger_executions_status")
    |> check_constraint(:executed_at, name: "trigger_executions_executed_at")
    |> check_constraint(:cooldown_until, name: "trigger_executions_cooldown_until")
    |> check_constraint(:error_class, name: "trigger_executions_error_class")
    |> unique_constraint([:trigger_id, :event_id],
      name: :trigger_executions_trigger_id_event_id_index
    )
  end

  defp invalid_changeset(execution) do
    execution
    |> change()
    |> add_error(:base, "is invalid")
  end
end

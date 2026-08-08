defmodule ClusterMurmur.Runtime.ResponderTurnSchedule do
  @moduledoc """
  Projects a bounded relative responder schedule from one proven base instant.

  Relative offsets let a reusable poll runtime construct fresh absolute turn
  timestamps for each cycle without an ambient clock or unbounded callback.
  Every external transport remains explicit and is never exposed by inspection.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Runtime.ResponderConversationRunner.Turn

  defmodule Step do
    @moduledoc false
    @derive {Inspect,
             only: [
               :planned_after_ms,
               :generated_after_ms,
               :publication_started_after_ms,
               :publication_completed_after_ms
             ]}
    @enforce_keys [
      :planned_after_ms,
      :generated_after_ms,
      :publication_started_after_ms,
      :publication_completed_after_ms,
      :generation_transport,
      :publication_transport
    ]
    defstruct [
      :planned_after_ms,
      :generated_after_ms,
      :publication_started_after_ms,
      :publication_completed_after_ms,
      :generation_transport,
      :publication_transport
    ]

    @type t :: %__MODULE__{
            planned_after_ms: non_neg_integer(),
            generated_after_ms: non_neg_integer(),
            publication_started_after_ms: non_neg_integer(),
            publication_completed_after_ms: non_neg_integer(),
            generation_transport: function(),
            publication_transport: function()
          }
  end

  @derive {Inspect, only: [:steps]}
  @enforce_keys [:steps]
  defstruct [:steps]

  @type t :: %__MODULE__{steps: [Step.t()]}

  @step_keys Step.__struct__() |> Map.keys()
  @step_key_count length(@step_keys)
  @schedule_keys [:__struct__, :steps]
  @schedule_key_count length(@schedule_keys)
  @max_steps 256
  @max_offset_ms DomainLimits.max_interval_ms()

  @doc "Validates one exact non-empty relative schedule."
  @spec validate(term()) :: :ok | {:error, :invalid_responder_turn_schedule}
  def validate(%__MODULE__{} = schedule) do
    if exact_schedule?(schedule),
      do: validate_steps(schedule.steps, nil, 0),
      else: {:error, :invalid_responder_turn_schedule}
  rescue
    _error -> {:error, :invalid_responder_turn_schedule}
  catch
    _kind, _reason -> {:error, :invalid_responder_turn_schedule}
  end

  def validate(_schedule), do: {:error, :invalid_responder_turn_schedule}

  @doc "Projects exact absolute runner turns relative to one storage UTC instant."
  @spec project(term(), term()) ::
          {:ok, [Turn.t()]} | {:error, :invalid_responder_turn_schedule}
  def project(%__MODULE__{} = schedule, base_at) do
    with :ok <- validate(schedule),
         :ok <- DateTimeValidator.validate_storage_utc(base_at),
         {:ok, turns} <- project_steps(schedule.steps, base_at, []) do
      {:ok, Enum.reverse(turns)}
    else
      _failure -> {:error, :invalid_responder_turn_schedule}
    end
  rescue
    _error -> {:error, :invalid_responder_turn_schedule}
  catch
    _kind, _reason -> {:error, :invalid_responder_turn_schedule}
  end

  def project(_schedule, _base_at), do: {:error, :invalid_responder_turn_schedule}

  defp validate_steps([], _previous_completed_after_ms, count) when count > 0, do: :ok

  defp validate_steps([_step | _steps], _previous, @max_steps),
    do: {:error, :invalid_responder_turn_schedule}

  defp validate_steps(
         [%Step{} = step | steps],
         previous_completed_after_ms,
         count
       ) do
    if exact_step?(step) and valid_offset?(step.planned_after_ms) and
         valid_offset?(step.generated_after_ms) and
         valid_offset?(step.publication_started_after_ms) and
         valid_offset?(step.publication_completed_after_ms) and
         ordered_step?(step, previous_completed_after_ms) and
         is_function(step.generation_transport, 1) and
         is_function(step.publication_transport, 1) do
      validate_steps(steps, step.publication_completed_after_ms, count + 1)
    else
      {:error, :invalid_responder_turn_schedule}
    end
  end

  defp validate_steps(_steps, _previous_completed_after_ms, _count),
    do: {:error, :invalid_responder_turn_schedule}

  defp project_steps([], _base_at, turns), do: {:ok, turns}

  defp project_steps([step | steps], base_at, turns) do
    turn = %Turn{
      planned_at: add_ms(base_at, step.planned_after_ms),
      generated_at: add_ms(base_at, step.generated_after_ms),
      publication_started_at: add_ms(base_at, step.publication_started_after_ms),
      publication_completed_at: add_ms(base_at, step.publication_completed_after_ms),
      generation_transport: step.generation_transport,
      publication_transport: step.publication_transport
    }

    if valid_projected_times?(turn),
      do: project_steps(steps, base_at, [turn | turns]),
      else: {:error, :invalid_responder_turn_schedule}
  end

  defp add_ms(base_at, offset_ms),
    do: DateTime.add(base_at, offset_ms * 1_000, :microsecond)

  defp ordered_step?(step, nil) do
    step.planned_after_ms <= step.generated_after_ms and
      step.generated_after_ms <= step.publication_started_after_ms and
      step.publication_started_after_ms <= step.publication_completed_after_ms
  end

  defp ordered_step?(step, previous_completed_after_ms) do
    previous_completed_after_ms <= step.planned_after_ms and ordered_step?(step, nil)
  end

  defp valid_offset?(value),
    do: is_integer(value) and value >= 0 and value <= @max_offset_ms

  defp valid_projected_times?(turn) do
    Enum.all?(
      [
        turn.planned_at,
        turn.generated_at,
        turn.publication_started_at,
        turn.publication_completed_at
      ],
      &(DateTimeValidator.validate_storage_utc(&1) == :ok)
    )
  end

  defp exact_schedule?(schedule),
    do:
      map_size(schedule) == @schedule_key_count and
        Enum.all?(@schedule_keys, &Map.has_key?(schedule, &1))

  defp exact_step?(step),
    do: map_size(step) == @step_key_count and Enum.all?(@step_keys, &Map.has_key?(step, &1))
end

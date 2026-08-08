defmodule ClusterMurmur.Triggers.AuthorizedStarterPipelineConsumer do
  @moduledoc """
  Consumes each poll authorization through one preflighted starter pipeline input.

  The context contains one authorization-free input per planned match. The full
  bounded batch is validated before the dispatcher authorizes its first action.
  Each authorization is then inserted only for its stable position and is never
  returned from this boundary.
  """

  @behaviour ClusterMurmur.Triggers.AuthorizedStarterConsumer

  alias ClusterMurmur.Config.Configuration
  alias ClusterMurmur.Observers.Poller.Result, as: PollResult

  alias ClusterMurmur.Triggers.{
    AuthorizedStarterPipeline,
    EventTriggerAuthorizer,
    PollEventTriggerPlanner
  }

  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.{Adapters, Input}
  alias ClusterMurmur.Triggers.EventTriggerAuthorizer.Authorization
  alias ClusterMurmur.Triggers.PollEventTriggerPlanner.Plan

  defmodule Context do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:inputs, :adapters]
    defstruct [:inputs, :adapters]

    @type t :: %__MODULE__{
            inputs: [ClusterMurmur.Triggers.AuthorizedStarterPipeline.Input.t()],
            adapters: ClusterMurmur.Triggers.AuthorizedStarterPipeline.Adapters.t()
          }
  end

  @context_keys Context.__struct__() |> Map.keys()
  @context_key_count length(@context_keys)
  @max_index 255

  @impl true
  def preflight(
        %Plan{} = plan,
        %PollResult{} = poll_result,
        %Configuration{} = configuration,
        %Context{} = context
      ) do
    with :ok <- PollEventTriggerPlanner.validate(plan, poll_result, configuration),
         true <- exact_context?(context),
         :ok <-
           validate_inputs(
             context.inputs,
             expected_events(plan.entries),
             plan.executed_at,
             context.adapters,
             configuration,
             MapSet.new()
           ) do
      :ok
    else
      _failure -> {:error, :invalid_starter_context}
    end
  rescue
    _error -> {:error, :invalid_starter_context}
  catch
    _kind, _reason -> {:error, :invalid_starter_context}
  end

  def preflight(_plan, _poll_result, _configuration, _context),
    do: {:error, :invalid_starter_context}

  @impl true
  def consume(%Authorization{} = authorization, index, %Context{} = context)
      when is_integer(index) and index >= 0 and index <= @max_index do
    with true <- exact_context?(context),
         :ok <- EventTriggerAuthorizer.validate(authorization),
         {:ok, %Input{authorization: nil} = input} <- Enum.fetch(context.inputs, index),
         :ok <- AuthorizedStarterPipeline.validate_shared_input(input, context.adapters),
         :ok <- run_pipeline(%{input | authorization: authorization}, context.adapters) do
      :ok
    else
      _failure -> {:error, :starter_failed}
    end
  rescue
    _error -> {:error, :starter_failed}
  catch
    _kind, _reason -> {:error, :starter_failed}
  end

  def consume(_authorization, _index, _context), do: {:error, :starter_failed}

  defp validate_inputs(
         [],
         [],
         _executed_at,
         _adapters,
         _configuration,
         _conversation_ids
       ),
       do: :ok

  defp validate_inputs(
         [%Input{authorization: nil} = input | inputs],
         [event | events],
         executed_at,
         %Adapters{} = adapters,
         configuration,
         conversation_ids
       ) do
    with true <- input.configuration === configuration,
         false <- MapSet.member?(conversation_ids, input.conversation_id),
         true <- not_before_match?(input.generated_at, event, executed_at),
         :ok <- AuthorizedStarterPipeline.validate_shared_input(input, adapters) do
      validate_inputs(
        inputs,
        events,
        executed_at,
        adapters,
        configuration,
        MapSet.put(conversation_ids, input.conversation_id)
      )
    else
      _failure -> {:error, :invalid_starter_context}
    end
  end

  defp validate_inputs(
         _inputs,
         _events,
         _executed_at,
         _adapters,
         _configuration,
         _conversation_ids
       ),
       do: {:error, :invalid_starter_context}

  defp expected_events(entries) do
    Enum.flat_map(entries, fn entry ->
      Enum.map(entry.triggers, fn _trigger -> entry.event end)
    end)
  end

  defp not_before_match?(generated_at, event, executed_at) do
    latest_event_at =
      case event.observed_at do
        nil ->
          event.occurred_at

        observed_at ->
          if DateTime.compare(observed_at, event.occurred_at) == :lt,
            do: event.occurred_at,
            else: observed_at
      end

    DateTime.compare(generated_at, latest_event_at) in [:gt, :eq] and
      DateTime.compare(generated_at, executed_at) in [:gt, :eq]
  end

  defp run_pipeline(input, adapters) do
    case AuthorizedStarterPipeline.run(input, adapters) do
      {:ok, _completed} -> :ok
      {:continue, :reply, _recorded} -> :ok
      _failure -> {:error, :starter_failed}
    end
  end

  defp exact_context?(context) do
    map_size(context) == @context_key_count and
      Enum.all?(@context_keys, &Map.has_key?(context, &1))
  end
end

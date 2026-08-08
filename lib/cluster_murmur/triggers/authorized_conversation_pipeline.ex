defmodule ClusterMurmur.Triggers.AuthorizedConversationPipeline do
  @moduledoc """
  Runs one authorized starter and its opt-in bounded responder schedule.

  The complete starter runtime, responder schedule, fixed adapters, and shared
  adapter correlations are validated before the starter pipeline mutates
  persistence. A responder runner is initialized only from an exact reply
  continuation returned by that pipeline. The coordinator performs no retries,
  observation, authorization, or ambient scheduling.
  """

  alias ClusterMurmur.Config.ConversationDefaults
  alias ClusterMurmur.Conversations.StarterReplyFinisher
  alias ClusterMurmur.Runtime.{ResponderConversationInitializer, ResponderConversationRunner}
  alias ClusterMurmur.Runtime.ResponderConversationInitializer.Input, as: InitializerInput
  alias ClusterMurmur.Runtime.ResponderConversationRunner.Turn
  alias ClusterMurmur.Runtime.ResponderTurnCycle

  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline
  alias ClusterMurmur.Triggers.AuthorizedStarterPipeline.Input, as: StarterInput

  defmodule Input do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [:starter, :responder_turns]
    defstruct [:starter, :responder_turns]

    @type t :: %__MODULE__{
            starter: ClusterMurmur.Triggers.AuthorizedStarterPipeline.Input.t(),
            responder_turns: [ClusterMurmur.Runtime.ResponderConversationRunner.Turn.t()]
          }
  end

  defmodule Adapters do
    @moduledoc false
    @derive {Inspect, only: []}
    @enforce_keys [:starter, :responder]
    defstruct [:starter, :responder]

    @type t :: %__MODULE__{
            starter: ClusterMurmur.Triggers.AuthorizedStarterPipeline.Adapters.t(),
            responder: ClusterMurmur.Runtime.ResponderTurnCycle.Adapters.t()
          }
  end

  @input_keys Input.__struct__() |> Map.keys()
  @input_key_count length(@input_keys)
  @adapter_keys Adapters.__struct__() |> Map.keys()
  @adapter_key_count length(@adapter_keys)

  @type result ::
          {:ok, StarterReplyFinisher.Completed.t()}
          | ResponderConversationRunner.result()
          | {:skip, :no_starter}
          | {:failed, atom(), ClusterMurmur.Discord.StarterPublicationExecutor.Outcome.t()}
          | {:ambiguous, :interrupted,
             ClusterMurmur.Discord.StarterPublicationExecutor.Outcome.t()}
          | {:error, atom()}

  @doc "Runs one exact starter and only its proven reply continuation."
  @spec run(term(), term()) :: result()
  def run(%Input{} = input, %Adapters{} = adapters) do
    with :ok <- validate_runtime(input, adapters) do
      input.starter
      |> AuthorizedStarterPipeline.run(adapters.starter)
      |> continue(input, adapters)
    else
      _failure -> {:error, :invalid_authorized_conversation_pipeline}
    end
  rescue
    _error -> {:error, :invalid_authorized_conversation_pipeline}
  catch
    _kind, _reason -> {:error, :invalid_authorized_conversation_pipeline}
  end

  def run(_input, _adapters), do: {:error, :invalid_authorized_conversation_pipeline}

  @doc "Validates the complete opt-in runtime before its first durable mutation."
  @spec validate_runtime(term(), term()) ::
          :ok | {:error, :invalid_authorized_conversation_pipeline}
  def validate_runtime(%Input{} = input, %Adapters{} = adapters) do
    with true <- exact_input?(input),
         true <- exact_adapters?(adapters),
         %StarterInput{} <- input.starter,
         %AuthorizedStarterPipeline.Adapters{} <- adapters.starter,
         %ResponderTurnCycle.Adapters{} <- adapters.responder,
         :ok <- AuthorizedStarterPipeline.validate_runtime(input.starter, adapters.starter),
         :ok <- ResponderTurnCycle.validate_adapters(adapters.responder),
         true <- shared_adapters?(adapters),
         {:ok, first_planned_at} <- first_planned_at(input.responder_turns),
         true <-
           DateTime.compare(first_planned_at, input.starter.publication_completed_at) in [
             :eq,
             :gt
           ],
         {:ok, deadline} <- duration_deadline(input.starter),
         :ok <-
           ResponderConversationRunner.validate_schedule(
             input.responder_turns,
             first_planned_at,
             deadline
           ) do
      :ok
    else
      _failure -> {:error, :invalid_authorized_conversation_pipeline}
    end
  rescue
    _error -> {:error, :invalid_authorized_conversation_pipeline}
  catch
    _kind, _reason -> {:error, :invalid_authorized_conversation_pipeline}
  end

  def validate_runtime(_input, _adapters),
    do: {:error, :invalid_authorized_conversation_pipeline}

  defp continue(
         {:continue, :reply, %StarterReplyFinisher.Continuation{} = continuation},
         input,
         adapters
       ) do
    starter = input.starter

    initializer = %InitializerInput{
      continuation: continuation,
      configuration: starter.configuration,
      starter_cooldowns: starter.cooldowns,
      webhook_settings: starter.webhook_settings,
      provider_settings: starter.provider_settings,
      turns: input.responder_turns
    }

    with {:ok, runner_input} <- ResponderConversationInitializer.initialize(initializer) do
      ResponderConversationRunner.run(runner_input, adapters.responder)
    else
      _failure -> {:error, :invalid_authorized_conversation_pipeline}
    end
  end

  defp continue({:ok, %StarterReplyFinisher.Completed{}} = completed, _input, _adapters),
    do: completed

  defp continue({:skip, :no_starter} = skipped, _input, _adapters), do: skipped

  defp continue({:failed, reason, outcome} = failed, _input, _adapters)
       when is_atom(reason) and is_struct(outcome),
       do: failed

  defp continue({:ambiguous, :interrupted, outcome} = ambiguous, _input, _adapters)
       when is_struct(outcome),
       do: ambiguous

  defp continue({:error, reason} = error, _input, _adapters) when is_atom(reason), do: error

  defp continue(_result, _input, _adapters),
    do: {:error, :invalid_authorized_conversation_pipeline}

  defp first_planned_at([%Turn{planned_at: planned_at} | _turns]), do: {:ok, planned_at}
  defp first_planned_at(_turns), do: {:error, :invalid_authorized_conversation_pipeline}

  defp duration_deadline(starter) do
    with {:ok, budget} <-
           ConversationDefaults.to_budget(starter.configuration.conversation_defaults) do
      {:ok,
       DateTime.add(
         starter.authorization.plan.executed_at,
         budget.max_duration_ms * 1_000,
         :microsecond
       )}
    end
  end

  defp shared_adapters?(adapters) do
    starter = adapters.starter
    responder = adapters.responder

    starter.conversation_store === responder.conversation_store and
      starter.provider === responder.provider and
      starter.message_store === responder.message_store and
      starter.publication_start_store === responder.publication_start_store and
      starter.publisher === responder.publisher and
      starter.publication_terminal_store === responder.publication_terminal_store and
      starter.cooldown_store === responder.cooldown_store
  end

  defp exact_input?(input),
    do: map_size(input) == @input_key_count and Enum.all?(@input_keys, &Map.has_key?(input, &1))

  defp exact_adapters?(adapters),
    do:
      map_size(adapters) == @adapter_key_count and
        Enum.all?(@adapter_keys, &Map.has_key?(adapters, &1))
end

defmodule ClusterMurmur.Conversations.ResponderSubsequentContinuationTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.{
    ResponderContinuationConsumer,
    ResponderContinuationPlanner,
    ResponderTurnFinisher
  }

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.{Input, Plan, Result}

  alias ClusterMurmur.Discord.{
    ResponderPublicationExecutor,
    ResponderPublicationPlanner,
    ResponderPublicationStarter
  }

  alias ClusterMurmur.Discord.ResponderPublicationExecutor.Outcome

  alias ClusterMurmur.Generation.ResponderMessageConsumer
  alias ClusterMurmur.Generation.ResponderMessageConsumer.ConsumerContext

  alias ClusterMurmur.Persistence.{MessageRecord, PersonaCooldownRecord, PublicationAttemptRecord}
  alias ClusterMurmur.Personas.ResponderCooldownRecorder
  alias ClusterMurmur.Personas.ResponderCooldownRecorder.Recorded
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @started_at ~U[2026-08-07 02:00:05.000000Z]
  @completed_at ~U[2026-08-07 02:00:06.000000Z]
  @planned_at ~U[2026-08-07 02:00:07.000000Z]

  defmodule FinisherStore do
    def wait(conversation), do: {:ok, %{conversation | status: :waiting}}

    def complete(conversation, completed_at),
      do: {:ok, %{conversation | status: :completed, completed_at: completed_at}}
  end

  defmodule ClaimStore do
    def seed(record), do: Process.put({__MODULE__, :record}, record)

    def claim_generation(waiting, persona_id) do
      if Process.get({__MODULE__, :record}) === waiting do
        generating = %{
          waiting
          | status: :generating,
            llm_call_count: waiting.llm_call_count + 1
        }

        Process.put({__MODULE__, :record}, {generating, persona_id})
        {:ok, generating}
      else
        {:error, :conversation_conflict}
      end
    end

    def consume_generation(generating, persona_id) do
      if Process.get({__MODULE__, :record}) === {generating, persona_id} do
        Process.put({__MODULE__, :record}, :consumed)
        :ok
      else
        {:error, :conversation_conflict}
      end
    end

    def confirm_completed(record) do
      if Process.get({__MODULE__, :record}) === record,
        do: :ok,
        else: {:error, :conversation_conflict}
    end

    def complete(waiting, completed_at) do
      if Process.get({__MODULE__, :record}) === waiting do
        completed = %{waiting | status: :completed, completed_at: completed_at}
        Process.put({__MODULE__, :record}, completed)
        {:ok, completed}
      else
        {:error, :conversation_conflict}
      end
    end
  end

  defmodule NoSelectionRandom do
    def weighted_choice(_outcomes), do: raise("no candidates must resolve without randomness")
  end

  defmodule ObserverRandom do
    def weighted_choice(_outcomes), do: {:ok, {:reply, "observer"}}
  end

  defmodule Provider do
    def generate(_request, _settings, transport), do: transport.(:request)
  end

  defmodule MessageStore do
    def append_reserved(conversation, generated) do
      send(self(), {:appended, generated})

      message =
        %MessageRecord{
          id: 3,
          conversation_id: generated.conversation_id,
          persona_id: generated.persona_id,
          origin: generated.origin,
          content: generated.content,
          discord_message_id: nil,
          inserted_at: generated.inserted_at
        }
        |> Ecto.put_meta(state: :loaded)

      {:ok, {message, %{conversation | turn_count: conversation.turn_count + 1}}}
    end
  end

  defmodule Consumer do
    def preflight(_input, process) do
      send(process, :preflighted)
      :ok
    end

    def consume(%Plan{outcome: :no_reply}, process) do
      send(process, :completed_without_reply)
      :ok
    end
  end

  test "accepts an exact published-responder continuation for the next bounded decision" do
    input = subsequent_input()
    ClaimStore.seed(input.continuation.conversation)

    assert {:ok, %Result{outcome: :no_reply, status: :dispatched, delivery: nil}} =
             ResponderContinuationPlanner.dispatch(
               input,
               NoSelectionRandom,
               ClaimStore,
               Consumer,
               self()
             )

    assert_receive :preflighted
    assert_receive :completed_without_reply

    responder = input.current_cooldowns["responder"]

    newer_responder = %{
      responder
      | last_spoken_at: DateTime.add(responder.last_spoken_at, 1, :second),
        cooldown_until: DateTime.add(responder.cooldown_until, 1, :second)
    }

    newer = %{
      input
      | current_cooldowns: Map.put(input.current_cooldowns, "responder", newer_responder)
    }

    ClaimStore.seed(newer.continuation.conversation)

    assert {:ok, %Result{outcome: :no_reply, status: :dispatched}} =
             ResponderContinuationPlanner.dispatch(
               newer,
               NoSelectionRandom,
               ClaimStore,
               Consumer,
               self()
             )

    assert_receive :preflighted
    assert_receive :completed_without_reply

    regressed_deadline = %{
      responder
      | last_spoken_at: DateTime.add(responder.last_spoken_at, 1, :second),
        cooldown_until: DateTime.add(responder.cooldown_until, -1, :second)
    }

    for forged <- [
          %{
            input
            | current_cooldowns:
                input.continuation.recorded.published.started.plan.delivery.plan.input.current_cooldowns
          },
          %{
            input
            | conversation: %{input.conversation | turn_count: input.conversation.turn_count - 1}
          },
          %{
            input
            | current_cooldowns: Map.put(input.current_cooldowns, "responder", regressed_deadline)
          },
          %{input | budget: %{input.budget | max_turns: input.budget.max_turns + 1}},
          %{input | planned_at: ~U[2026-08-07 02:00:05.000000Z]},
          %{input | starter_cooldowns: %{"forged" => input.continuation.recorded.cooldown}}
        ] do
      assert ResponderContinuationPlanner.dispatch(
               forged,
               NoSelectionRandom,
               ClaimStore,
               Consumer,
               self()
             ) == {:error, :invalid_responder_continuation}
    end
  end

  test "real message consumer generates a subsequent reply from the recursive event chain" do
    configuration = configuration_with_observer()
    input = subsequent_input(configuration)
    ClaimStore.seed(input.continuation.conversation)

    context = %ConsumerContext{
      input: input,
      provider_settings: RuntimeFixture.provider_settings(),
      inserted_at: @planned_at,
      provider: Provider,
      transport: fn :request -> {:ok, "A second factual response."} end,
      conversation_store: ClaimStore,
      message_store: MessageStore
    }

    assert {:ok, %Result{outcome: :reply, status: :dispatched, delivery: delivery}} =
             ResponderContinuationPlanner.dispatch(
               input,
               ObserverRandom,
               ClaimStore,
               ResponderMessageConsumer,
               context
             )

    assert delivery.message.persona_id == "observer"
    assert_receive {:appended, generated}
    assert generated.content == "A second factual response."
  end

  defp subsequent_input(configuration \\ RuntimeFixture.responder_configuration()) do
    original_input = RuntimeFixture.responder_input(configuration)
    delivery = RuntimeFixture.responder_delivery(configuration)

    budget =
      if Map.has_key?(configuration.personas.personas, "observer"),
        do: %{original_input.budget | max_participants: 3},
        else: original_input.budget

    initial = %{original_input | budget: budget}
    responder_plan = %{delivery.plan | input: %{delivery.plan.input | budget: budget}}
    delivery = %{delivery | plan: responder_plan}
    :ok = ResponderContinuationConsumer.validate_delivery(delivery, responder_plan)

    {:ok, publication_plan} =
      ResponderPublicationPlanner.plan(
        delivery,
        configuration,
        initial.current_cooldowns,
        initial.webhook_settings
      )

    started_attempt =
      %PublicationAttemptRecord{
        message_id: delivery.message.id,
        status: :started,
        started_at: @started_at,
        completed_at: nil,
        error_class: nil
      }
      |> Ecto.put_meta(state: :loaded)

    started = %ResponderPublicationStarter.Started{
      plan: publication_plan,
      attempt: started_attempt
    }

    published = %Outcome{
      started: started,
      attempt: %{
        started_attempt
        | status: :succeeded,
          completed_at: @completed_at,
          error_class: nil
      },
      message: %{delivery.message | discord_message_id: "23456"},
      status: :succeeded,
      error_class: nil
    }

    :ok =
      ResponderPublicationExecutor.validate(
        published,
        configuration,
        initial.current_cooldowns,
        initial.webhook_settings
      )

    cooldown =
      %PersonaCooldownRecord{
        persona_id: "responder",
        last_spoken_at: @completed_at,
        cooldown_until: ~U[2026-08-07 02:01:06.000000Z]
      }
      |> Ecto.put_meta(state: :loaded)

    recorded = %Recorded{published: published, cooldown: cooldown}

    :ok =
      ResponderCooldownRecorder.validate(
        recorded,
        configuration,
        initial.current_cooldowns,
        initial.webhook_settings
      )

    assert {:continue, continuation} =
             ResponderTurnFinisher.finish(
               recorded,
               configuration,
               initial.current_cooldowns,
               initial.webhook_settings,
               FinisherStore
             )

    %Input{
      continuation: continuation,
      configuration: configuration,
      starter_cooldowns: initial.starter_cooldowns,
      current_cooldowns: continuation.current_cooldowns,
      webhook_settings: initial.webhook_settings,
      conversation: continuation.runtime,
      budget: initial.budget,
      planned_at: @planned_at,
      policy: initial.policy,
      no_reply_weight: initial.no_reply_weight
    }
  end

  defp configuration_with_observer do
    configuration = RuntimeFixture.responder_configuration()
    responder = configuration.personas.personas["responder"]

    observer = %{
      responder
      | id: "observer",
        display_name: "Observer",
        prompt: "Reply using only supplied facts.",
        behavior: %{"reply_weight" => 1, "cooldown_ms" => 60_000}
    }

    binding = configuration.bindings.bindings["characters"]

    configuration
    |> put_in([Access.key(:personas), Access.key(:personas), "observer"], observer)
    |> put_in(
      [Access.key(:bindings), Access.key(:bindings), "characters", Access.key(:candidates)],
      binding.candidates ++ [%{persona: "observer", weight: 1}]
    )
  end
end

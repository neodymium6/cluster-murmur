defmodule ClusterMurmur.Conversations.ResponderContinuationPlannerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.{Bindings, Personas}

  alias ClusterMurmur.Conversations.{
    Budget,
    Conversation,
    ResponderContinuationPlanner,
    StarterReplyFinisher
  }

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.{Input, Plan, Result}
  alias ClusterMurmur.Messages.Message
  alias ClusterMurmur.Persistence.PersonaCooldownRecord
  alias ClusterMurmur.Personas.ResponderPolicy
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @planned_at ~U[2026-08-07 02:00:03.000000Z]

  defmodule WaitingStore do
    def wait(conversation), do: {:ok, %{conversation | status: :waiting}}

    def complete(conversation, completed_at),
      do: {:ok, %{conversation | status: :completed, completed_at: completed_at}}
  end

  defmodule ClaimStore do
    def seed(record), do: Process.put({__MODULE__, :record}, record)

    def claim_generation(waiting) do
      if Process.get({__MODULE__, :record}) === waiting do
        generating = %{waiting | status: :generating}
        Process.put({__MODULE__, :record}, generating)
        {:ok, generating}
      else
        {:error, :conversation_conflict}
      end
    end
  end

  defmodule ReplyRandom do
    def weighted_choice(outcomes) do
      send(self(), {:selected_from, outcomes})
      {:ok, {:reply, "responder"}}
    end
  end

  defmodule NoReplyRandom do
    def weighted_choice(outcomes) do
      send(self(), {:selected_from, outcomes})
      {:ok, :no_reply}
    end
  end

  defmodule RaisingReplyGateRandom do
    def uniform, do: raise("endpoint probability must not sample")
  end

  defmodule Consumer do
    @behaviour ClusterMurmur.Conversations.ResponderContinuationConsumer

    @impl true
    def preflight(_input, context) do
      send(context, :consumer_preflighted)
      :ok
    end

    @impl true
    def consume(plan, context) do
      send(context, {:consumed, plan})
      :ok
    end
  end

  defmodule FailingConsumer do
    def preflight(_input, context) do
      send(context, :consumer_preflighted)
      :ok
    end

    def consume(_plan, _context), do: raise("private consumer failure")
  end

  test "synchronously dispatches the sampled responder without returning its capability" do
    input = input()

    assert {:ok, %Result{outcome: :reply, status: :dispatched, reason: nil} = result} =
             ResponderContinuationPlanner.dispatch(
               input,
               ReplyRandom,
               ClaimStore,
               Consumer,
               self()
             )

    assert_receive :consumer_preflighted

    assert_receive {:selected_from, [{{:reply, "responder"}, 5}, {:no_reply, 1}]}

    assert_receive {:consumed, %Plan{} = plan}
    assert plan.outcome == :reply
    assert plan.responder.id == "responder"
    assert plan.binding.id == "characters"
    assert plan.conversation.status == :generating
    assert plan.planned_at == @planned_at

    inspected = inspect(result) <> inspect(input)
    refute inspected =~ "private fact"
    refute inspected =~ "fake-token"
    refute inspected =~ "responder"
  end

  test "synchronously dispatches the sampled explicit no-reply outcome" do
    assert {:ok, %Result{outcome: :no_reply, status: :dispatched}} =
             ResponderContinuationPlanner.dispatch(
               input(),
               NoReplyRandom,
               ClaimStore,
               Consumer,
               self()
             )

    assert_receive :consumer_preflighted
    assert_receive {:selected_from, _outcomes}
    assert_receive {:consumed, %Plan{outcome: :no_reply, responder: nil}}
  end

  test "preflights the consumer before selection and contains consumption failures" do
    assert {:ok, %Result{outcome: :reply, status: :failed, reason: :dispatch_failed}} =
             ResponderContinuationPlanner.dispatch(
               input(),
               ReplyRandom,
               ClaimStore,
               FailingConsumer,
               self()
             )

    assert_receive :consumer_preflighted
    assert_receive {:selected_from, _outcomes}
  end

  test "separates historical starter cooldowns from the current responder view" do
    valid = input()

    responder_cooldown =
      %PersonaCooldownRecord{
        persona_id: "responder",
        last_spoken_at: @planned_at,
        cooldown_until: DateTime.add(@planned_at, 60, :second)
      }
      |> Ecto.put_meta(state: :loaded)

    current = Map.put(valid.current_cooldowns, "responder", responder_cooldown)

    assert {:ok, %Result{outcome: :no_reply, status: :dispatched}} =
             ResponderContinuationPlanner.dispatch(
               %{valid | current_cooldowns: current},
               NoReplyRandom,
               ClaimStore,
               Consumer,
               self()
             )

    assert_receive :consumer_preflighted
    assert_receive {:consumed, %Plan{outcome: :no_reply}}
    refute_received {:selected_from, _outcomes}
  end

  test "rejects stale current facts and forged correlations before preflight or selection" do
    valid = input()
    starter_id = valid.continuation.recorded.cooldown.persona_id

    stale =
      %{valid.continuation.recorded.cooldown | last_spoken_at: ~U[2026-08-07 02:00:02.000000Z]}

    invalid = [
      %{valid | current_cooldowns: %{}},
      %{valid | current_cooldowns: %{starter_id => stale}},
      %{valid | conversation: %{valid.conversation | status: :starting}},
      %{valid | conversation: %{valid.conversation | id: "other-conversation"}},
      %{valid | conversation: %{valid.conversation | participants: [starter_id, "responder"]}},
      %{valid | planned_at: ~U[2026-08-07 02:00:00.000000Z]},
      %{valid | no_reply_weight: 0},
      Map.put(valid, :private, true)
    ]

    for rejected <- invalid do
      assert ResponderContinuationPlanner.dispatch(
               rejected,
               ReplyRandom,
               ClaimStore,
               Consumer,
               self()
             ) ==
               {:error, :invalid_responder_continuation}
    end

    refute_received :consumer_preflighted
    refute_received {:selected_from, _outcomes}
    refute_received {:consumed, _plan}
  end

  test "claims the authoritative waiting row once before consumption" do
    valid = input()

    assert {:ok, %Result{status: :dispatched}} =
             ResponderContinuationPlanner.dispatch(
               valid,
               ReplyRandom,
               ClaimStore,
               Consumer,
               self()
             )

    assert_receive :consumer_preflighted
    assert_receive {:selected_from, _outcomes}
    assert_receive {:consumed, %Plan{conversation: %{status: :generating}}}

    assert ResponderContinuationPlanner.dispatch(
             valid,
             ReplyRandom,
             ClaimStore,
             Consumer,
             self()
           ) == {:error, :invalid_responder_continuation}

    assert_receive :consumer_preflighted
    assert_receive {:selected_from, _outcomes}
    refute_received {:consumed, _plan}
  end

  test "rejects a structurally forged continuation when the authoritative row is terminal" do
    valid = input()
    waiting = valid.continuation.conversation
    ClaimStore.seed(%{waiting | status: :completed, completed_at: @planned_at})

    assert ResponderContinuationPlanner.dispatch(
             valid,
             ReplyRandom,
             ClaimStore,
             Consumer,
             self()
           ) == {:error, :invalid_responder_continuation}

    assert_receive :consumer_preflighted
    assert_receive {:selected_from, _outcomes}
    refute_received {:consumed, _plan}
  end

  defp input do
    configuration = configuration()
    settings = RuntimeFixture.webhook_settings()
    recorded = RuntimeFixture.recorded(configuration)

    assert {:continue, :reply, continuation} =
             StarterReplyFinisher.finish(
               recorded,
               configuration,
               %{},
               settings,
               RaisingReplyGateRandom,
               WaitingStore
             )

    ClaimStore.seed(continuation.conversation)

    %Input{
      continuation: continuation,
      configuration: configuration,
      starter_cooldowns: %{},
      current_cooldowns: %{recorded.cooldown.persona_id => recorded.cooldown},
      webhook_settings: settings,
      conversation: conversation(continuation, recorded),
      budget: %Budget{
        max_turns: 3,
        max_participants: 2,
        max_duration_ms: 300_000,
        max_llm_calls: 3
      },
      planned_at: @planned_at,
      policy: %ResponderPolicy{
        allow_same_persona_consecutively: false,
        allow_persona_reentry: false
      },
      no_reply_weight: 1
    }
  end

  defp configuration do
    configuration = RuntimeFixture.configuration()
    caretaker = configuration.personas.personas["caretaker"]

    responder = %{
      caretaker
      | id: "responder",
        display_name: "Responder",
        interests: %{"operations" => 2},
        behavior: %{"reply_weight" => 2, "cooldown_ms" => 60_000}
    }

    binding = configuration.bindings.bindings["characters"]
    binding = %{binding | candidates: binding.candidates ++ [%{persona: "responder", weight: 1}]}

    configuration
    |> put_in(
      [Access.key(:event_groups), Access.key(:groups), "operations", :reply_probability],
      1
    )
    |> Map.put(:personas, %Personas{
      personas: %{"caretaker" => caretaker, "responder" => responder}
    })
    |> Map.put(:bindings, %Bindings{bindings: %{"characters" => binding}})
  end

  defp conversation(continuation, recorded) do
    waiting = continuation.conversation
    published = recorded.published.message

    message = %Message{
      conversation_id: published.conversation_id,
      persona_id: published.persona_id,
      origin: published.origin,
      content: published.content,
      discord_message_id: published.discord_message_id,
      inserted_at: published.inserted_at
    }

    %Conversation{
      id: waiting.id,
      root_event_id: waiting.root_event_id,
      status: waiting.status,
      started_at: waiting.started_at,
      last_message_at: message.inserted_at,
      turn_count: waiting.turn_count,
      llm_call_count: waiting.llm_call_count,
      participants: [message.persona_id],
      messages: [message]
    }
  end
end

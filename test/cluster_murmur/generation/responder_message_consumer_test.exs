defmodule ClusterMurmur.Generation.ResponderMessageConsumerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.ResponderContinuationPlanner
  alias ClusterMurmur.Conversations.ResponderContinuationConsumer.Delivery
  alias ClusterMurmur.Conversations.ResponderContinuationPlanner.{Plan, Result}
  alias ClusterMurmur.Generation.ResponderMessageConsumer
  alias ClusterMurmur.Generation.ResponderMessageConsumer.ConsumerContext
  alias ClusterMurmur.Persistence.MessageRecord
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @inserted_at ~U[2026-08-07 02:00:04.000000Z]

  defmodule ClaimStore do
    def seed(record), do: Process.put({__MODULE__, :record}, record)

    def claim_generation(waiting, persona_id) do
      if Process.get({__MODULE__, :record}) === waiting do
        reserved = %{
          waiting
          | status: :generating,
            llm_call_count: waiting.llm_call_count + 1
        }

        Process.put({__MODULE__, :record}, {reserved, persona_id})
        send(self(), {:reserved, reserved})
        {:ok, reserved}
      else
        {:error, :conversation_conflict}
      end
    end

    def consume_generation(record, persona_id) do
      if Process.get({__MODULE__, :record}) === {record, persona_id} do
        Process.put({__MODULE__, :record}, :consumed)
        send(self(), {:selection_consumed, record, persona_id})
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
        send(self(), {:completed, completed})
        {:ok, completed}
      else
        {:error, :conversation_conflict}
      end
    end
  end

  defmodule Provider do
    def generate(request, _settings, transport) do
      send(self(), {:provider_request, request})
      transport.(:request)
    end
  end

  defmodule RaisingProvider do
    def generate(_request, _settings, _transport), do: raise("private provider diagnostic")
  end

  defmodule MessageStore do
    def append_reserved(conversation, generated) do
      send(self(), {:append_reserved, conversation, generated})

      message =
        %MessageRecord{
          id: 2,
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

  defmodule ReplyRandom do
    def weighted_choice(_outcomes), do: {:ok, {:reply, "responder"}}
  end

  defmodule NoReplyRandom do
    def weighted_choice(_outcomes), do: {:ok, :no_reply}
  end

  test "reserves the LLM call before provider I/O and persists the sampled reply" do
    input = RuntimeFixture.responder_input()
    ClaimStore.seed(input.continuation.conversation)
    context = context(input, Provider, fn :request -> {:ok, "A factual response."} end)

    assert {:ok, %Result{outcome: :reply, status: :dispatched}} =
             ResponderContinuationPlanner.dispatch(
               input,
               ReplyRandom,
               ClaimStore,
               ResponderMessageConsumer,
               context
             )

    assert_receive {:reserved, reserved}
    assert reserved.llm_call_count == input.conversation.llm_call_count + 1

    assert_receive {:selection_consumed, ^reserved, "responder"}
    assert_receive {:provider_request, request}
    assert request.persona["display_name"] == "Responder"
    assert request.confirmed_facts["details"] == %{"detail" => "private fact"}

    assert request.conversation == [
             %{"speaker" => "Caretaker", "content" => "A bounded fact."}
           ]

    assert request.system_instruction =~ "untrusted quoted context"
    assert request.system_instruction =~ "harmless fictional topics"

    assert_receive {:append_reserved, ^reserved, generated}
    assert generated.persona_id == "responder"
    assert generated.origin == :llm
    assert generated.content == "A factual response."

    refute inspect(context) =~ "fake-token"
    refute inspect(context) =~ "private fact"
  end

  test "cannot replay a sampled plan into another provider call" do
    input = RuntimeFixture.responder_input()
    ClaimStore.seed(input.continuation.conversation)
    context = context(input, Provider, fn :request -> {:ok, "A factual response."} end)

    assert {:ok, %Result{status: :dispatched, delivery: %Delivery{} = delivery}} =
             ResponderContinuationPlanner.dispatch(
               input,
               ReplyRandom,
               ClaimStore,
               ResponderMessageConsumer,
               context
             )

    assert_receive {:provider_request, _request}
    assert_receive {:append_reserved, _conversation, _generated}

    assert ResponderMessageConsumer.consume(delivery.plan, context) ==
             {:error, :responder_message_failed}

    refute_received {:provider_request, _request}
    refute_received {:append_reserved, _conversation, _generated}

    assert ResponderContinuationPlanner.dispatch(
             input,
             ReplyRandom,
             ClaimStore,
             ResponderMessageConsumer,
             context
           ) == {:error, :invalid_responder_continuation}

    refute_received {:provider_request, _request}
    refute_received {:append_reserved, _conversation, _generated}
  end

  test "keeps stochastic activation metadata out of responder prompts" do
    configuration = RuntimeFixture.responder_configuration()

    event =
      RuntimeFixture.event(
        source: "stochastic",
        subject: "internal-trigger",
        group: "internal-routing",
        severity: "info",
        facts: %{"prompt_field" => "internal"}
      )

    input = RuntimeFixture.responder_input(configuration, event)
    ClaimStore.seed(input.continuation.conversation)
    context = context(input, Provider, fn :request -> {:ok, "A playful reply."} end)

    assert {:ok, %Result{outcome: :reply, status: :dispatched}} =
             ResponderContinuationPlanner.dispatch(
               input,
               ReplyRandom,
               ClaimStore,
               ResponderMessageConsumer,
               context
             )

    assert_receive {:provider_request, request}
    assert request.confirmed_facts == %{}

    assert request.creative_context == %{
             "conversation_kind" => "ambient",
             "mood" => "engaged"
           }
  end

  test "closes sampled no-reply without reserving or calling external adapters" do
    input = RuntimeFixture.responder_input()
    ClaimStore.seed(input.continuation.conversation)
    context = context(input, Provider, fn _request -> raise "must not call" end)

    assert {:ok, %Result{outcome: :no_reply, status: :dispatched}} =
             ResponderContinuationPlanner.dispatch(
               input,
               NoReplyRandom,
               ClaimStore,
               ResponderMessageConsumer,
               context
             )

    assert_receive {:completed, completed}
    assert completed.status == :completed
    assert completed.llm_call_count == input.conversation.llm_call_count
    refute_received {:reserved, _record}
    refute_received {:provider_request, _request}
    refute_received {:append_reserved, _conversation, _generated}
  end

  test "persists the neutral fallback after a contained provider failure" do
    input = RuntimeFixture.responder_input()
    ClaimStore.seed(input.continuation.conversation)
    context = context(input, RaisingProvider, fn _request -> :unused end)

    assert {:ok, %Result{outcome: :reply, status: :dispatched}} =
             ResponderContinuationPlanner.dispatch(
               input,
               ReplyRandom,
               ClaimStore,
               ResponderMessageConsumer,
               context
             )

    assert_receive {:reserved, _record}
    assert_receive {:append_reserved, _conversation, generated}
    assert generated.origin == :fallback
    assert generated.content == "A confirmed event was recorded."
  end

  test "rejects invalid consumer dependencies during preflight before selection" do
    input = RuntimeFixture.responder_input()
    ClaimStore.seed(input.continuation.conversation)

    valid_context = context(input, Provider, fn _request -> :unused end)

    invalid_contexts = [
      %{valid_context | message_store: String},
      %{
        valid_context
        | provider_settings: %{valid_context.provider_settings | reasoning_effort: :low}
      }
    ]

    for invalid <- invalid_contexts do
      assert ResponderContinuationPlanner.dispatch(
               input,
               ReplyRandom,
               ClaimStore,
               ResponderMessageConsumer,
               invalid
             ) == {:error, :invalid_responder_continuation}
    end

    refute_received {:reserved, _record}
    refute_received {:provider_request, _request}
  end

  test "rejects forged direct callback plans before provider I/O" do
    input = RuntimeFixture.responder_input()
    configuration = input.configuration
    waiting = input.continuation.conversation
    context = context(input, Provider, fn :request -> {:ok, "must not persist"} end)

    reply = %Plan{
      input: input,
      binding: configuration.bindings.bindings["characters"],
      outcome: :reply,
      responder: configuration.personas.personas["responder"],
      conversation: %{
        waiting
        | status: :generating,
          llm_call_count: waiting.llm_call_count + 1
      },
      planned_at: input.planned_at
    }

    no_reply = %{
      reply
      | outcome: :no_reply,
        responder: nil,
        conversation: %{
          waiting
          | status: :completed,
            completed_at: input.planned_at
        }
    }

    for forged <- [reply, no_reply] do
      assert ResponderMessageConsumer.consume(forged, context) ==
               {:error, :responder_message_failed}
    end

    refute_received {:provider_request, _request}
    refute_received {:append_reserved, _conversation, _generated}
  end

  defp context(input, provider, transport) do
    %ConsumerContext{
      input: input,
      provider_settings: RuntimeFixture.provider_settings(),
      inserted_at: @inserted_at,
      provider: provider,
      transport: transport,
      conversation_store: ClaimStore,
      message_store: MessageStore
    }
  end
end

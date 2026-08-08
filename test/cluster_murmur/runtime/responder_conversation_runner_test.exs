defmodule ClusterMurmur.Runtime.ResponderConversationRunnerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Bindings, as: BindingCatalog
  alias ClusterMurmur.Config.Personas, as: PersonaCatalog
  alias ClusterMurmur.Conversations.ResponderTurnFinisher.{Completed, Continuation}
  alias ClusterMurmur.Persistence.{MessageRecord, PersonaCooldownRecord, PublicationAttemptRecord}
  alias ClusterMurmur.Runtime.ResponderConversationRunner
  alias ClusterMurmur.Runtime.ResponderConversationRunner.{Input, Turn}
  alias ClusterMurmur.Runtime.ResponderTurnCycle.Adapters
  alias ClusterMurmur.TestSupport.RuntimeFixture

  defmodule SequenceRandom do
    def weighted_choice(choices) do
      [outcome | rest] = Process.get({__MODULE__, :outcomes}, [])
      Process.put({__MODULE__, :outcomes}, rest)
      send(self(), {:selected, outcome, choices})
      {:ok, outcome}
    end
  end

  defmodule ConversationStore do
    def claim_generation(waiting, persona_id) do
      send(self(), {:claim_generation, persona_id})

      {:ok,
       %{
         waiting
         | status: :generating,
           llm_call_count: waiting.llm_call_count + 1
       }}
    end

    def consume_generation(_generating, persona_id) do
      send(self(), {:consume_generation, persona_id})
      :ok
    end

    def confirm_completed(completed) do
      send(self(), {:confirm_completed, completed.completed_at})
      :ok
    end

    def wait(active) do
      send(self(), {:wait, active.turn_count})
      {:ok, %{active | status: :waiting}}
    end

    def complete(active, completed_at) do
      send(self(), {:complete, active.turn_count, completed_at})
      {:ok, %{active | status: :completed, completed_at: completed_at}}
    end
  end

  defmodule Provider do
    def generate(request, _settings, transport) do
      send(self(), {:generate, request.persona["display_name"]})
      transport.(:request)
    end
  end

  defmodule MessageStore do
    def append_reserved(conversation, generated) do
      send(self(), {:append_reserved, generated.persona_id, generated.content})

      message =
        %MessageRecord{
          id: conversation.turn_count + 1,
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

  defmodule PublicationStartStore do
    def start(_publication, message, _persona, _settings, started_at) do
      send(self(), {:start_publication, message.persona_id, started_at})

      attempt =
        %PublicationAttemptRecord{
          message_id: message.id,
          status: :started,
          started_at: started_at,
          completed_at: nil,
          error_class: nil
        }
        |> Ecto.put_meta(state: :loaded)

      {:ok, attempt}
    end
  end

  defmodule Publisher do
    def publish(attempt, _publication, message, _persona, _settings, transport) do
      send(self(), {:publish, message.persona_id})
      transport.(:request)
      dispatching = %{attempt | status: :dispatching}

      case Process.get({__MODULE__, :outcome}, :success) do
        :success -> {:ok, "#{message.id}2345", dispatching}
        {:failed, reason} -> {:failed, reason, dispatching}
      end
    end
  end

  defmodule PublicationTerminalStore do
    def succeed(dispatching, message, discord_message_id, completed_at) do
      send(self(), {:succeed_publication, message.persona_id, completed_at})

      attempt = %{
        dispatching
        | status: :succeeded,
          completed_at: completed_at,
          error_class: nil
      }

      {:ok, {attempt, %{message | discord_message_id: discord_message_id}}}
    end

    def fail(dispatching, reason, completed_at) do
      send(self(), {:fail_publication, reason, completed_at})

      {:ok,
       %{
         dispatching
         | status: :failed,
           completed_at: completed_at,
           error_class: reason
       }}
    end

    def mark_ambiguous(dispatching, completed_at) do
      {:ok,
       %{
         dispatching
         | status: :ambiguous,
           completed_at: completed_at,
           error_class: :interrupted
       }}
    end
  end

  defmodule CooldownStore do
    def record_spoken(persona_id, spoken_at, cooldown_until) do
      send(self(), {:record_spoken, persona_id, spoken_at})

      cooldown =
        %PersonaCooldownRecord{
          persona_id: persona_id,
          last_spoken_at: spoken_at,
          cooldown_until: cooldown_until
        }
        |> Ecto.put_meta(state: :loaded)

      {:ok, cooldown}
    end
  end

  setup do
    Process.delete({Publisher, :outcome})
    Process.put({SequenceRandom, :outcomes}, [])
    :ok
  end

  test "runs exact continuations until the immutable budget completes" do
    Process.put(
      {SequenceRandom, :outcomes},
      [{:reply, "responder"}, {:reply, "third"}]
    )

    assert {:ok, %Completed{} = completed} =
             ResponderConversationRunner.run(input(turns()), adapters())

    assert completed.conversation.status == :completed
    assert completed.conversation.turn_count == 3
    assert completed.conversation.llm_call_count == 3
    assert completed.runtime.participants == ["caretaker", "responder", "third"]

    assert Enum.map(completed.runtime.messages, & &1.persona_id) == [
             "caretaker",
             "responder",
             "third"
           ]

    assert_receive {:selected, {:reply, "responder"}, _choices}
    assert_receive {:generate, "Responder"}
    assert_receive {:append_reserved, "responder", "First response."}
    assert_receive {:publish, "responder"}
    assert_receive {:record_spoken, "responder", ~U[2026-08-07 02:00:06.000000Z]}
    assert_receive {:wait, 2}

    assert_receive {:selected, {:reply, "third"}, _choices}
    assert_receive {:generate, "Third"}
    assert_receive {:append_reserved, "third", "Second response."}
    assert_receive {:publish, "third"}
    assert_receive {:record_spoken, "third", ~U[2026-08-07 02:00:10.000000Z]}
    assert_receive {:complete, 3, ~U[2026-08-07 02:00:10.000000Z]}

    assert Process.get({SequenceRandom, :outcomes}) == []
    refute inspect({input(turns()), completed}) =~ "fake-token"
    refute inspect({input(turns()), completed}) =~ "private fact"
  end

  test "returns the exact waiting continuation when the finite schedule ends" do
    Process.put({SequenceRandom, :outcomes}, [{:reply, "responder"}])

    assert {:continue, %Continuation{} = continuation} =
             ResponderConversationRunner.run(input([hd(turns())]), adapters())

    assert continuation.conversation.status == :waiting
    assert continuation.conversation.turn_count == 2
    assert continuation.budget_state.open?
    assert_receive {:wait, 2}
    refute_received {:complete, 2, _completed_at}
    assert Process.get({SequenceRandom, :outcomes}) == []
  end

  test "stops immediately on no reply or a known publication failure" do
    Process.put({SequenceRandom, :outcomes}, [:no_reply, {:reply, "third"}])

    assert {:ok, :no_reply, result} =
             ResponderConversationRunner.run(input(turns()), adapters())

    assert result.outcome == :no_reply
    assert_receive {:complete, 1, ~U[2026-08-07 02:00:03.000000Z]}
    refute_received {:generate, _persona}
    refute_received {:publish, _persona}
    assert Process.get({SequenceRandom, :outcomes}) == [{:reply, "third"}]

    flush_mailbox()
    Process.put({SequenceRandom, :outcomes}, [{:reply, "responder"}, {:reply, "third"}])
    Process.put({Publisher, :outcome}, {:failed, :timeout})

    assert {:failed, :timeout, failed} =
             ResponderConversationRunner.run(input(turns()), adapters())

    assert failed.status == :failed
    assert_receive {:fail_publication, :timeout, ~U[2026-08-07 02:00:06.000000Z]}
    refute_received {:record_spoken, "responder", _spoken_at}
    refute_received {:wait, 2}
    assert Process.get({SequenceRandom, :outcomes}) == [{:reply, "third"}]
  end

  test "preflights the complete schedule before the first durable selection" do
    [first, second] = turns()
    invalid_second = %{second | generated_at: DateTime.add(second.planned_at, -1, :second)}

    Process.put({SequenceRandom, :outcomes}, [{:reply, "responder"}])

    assert ResponderConversationRunner.run(input([first, invalid_second]), adapters()) ==
             {:error, :invalid_responder_conversation}

    assert ResponderConversationRunner.run(input([]), adapters()) ==
             {:error, :invalid_responder_conversation}

    assert ResponderConversationRunner.run(
             input([first]),
             %{adapters() | publisher: String}
           ) == {:error, :invalid_responder_conversation}

    refute_received {:selected, _outcome, _choices}
    refute_received {:claim_generation, _persona_id}
    refute_received {:generate, _persona}
    refute_received {:start_publication, _persona_id, _started_at}
    assert Process.get({SequenceRandom, :outcomes}) == [{:reply, "responder"}]
  end

  test "rejects a later effect that crosses the immutable duration deadline before selecting" do
    runner_input = input(turns())
    continuation = runner_input.continuation

    expiring = %{
      runner_input
      | continuation: %{
          continuation
          | budget: %{continuation.budget | max_duration_ms: 8_000}
        }
    }

    Process.put(
      {SequenceRandom, :outcomes},
      [{:reply, "responder"}, {:reply, "third"}]
    )

    assert ResponderConversationRunner.run(expiring, adapters()) ==
             {:error, :invalid_responder_conversation}

    refute_received {:selected, _outcome, _choices}
    refute_received {:claim_generation, _persona_id}
    refute_received {:generate, _persona}
    refute_received {:publish, _persona}
  end

  test "a turn planned at the duration deadline closes without external effects" do
    runner_input = input([hd(turns())])
    continuation = runner_input.continuation

    expired = %{
      runner_input
      | continuation: %{
          continuation
          | budget: %{continuation.budget | max_duration_ms: 3_000}
        }
    }

    Process.put({SequenceRandom, :outcomes}, [{:reply, "responder"}])

    assert {:ok, :no_reply, result} =
             ResponderConversationRunner.run(expired, adapters())

    assert result.outcome == :no_reply
    assert_receive {:complete, 1, ~U[2026-08-07 02:00:03.000000Z]}
    refute_received {:selected, _outcome, _choices}
    refute_received {:claim_generation, _persona_id}
    refute_received {:generate, _persona}
    refute_received {:publish, _persona}
    assert Process.get({SequenceRandom, :outcomes}) == [{:reply, "responder"}]
  end

  defp input(turns) do
    continuation = three_person_continuation()

    %Input{
      continuation: continuation,
      provider_settings: RuntimeFixture.provider_settings(),
      turns: turns
    }
  end

  defp turns do
    [
      turn(
        ~U[2026-08-07 02:00:03.000000Z],
        ~U[2026-08-07 02:00:04.000000Z],
        ~U[2026-08-07 02:00:05.000000Z],
        ~U[2026-08-07 02:00:06.000000Z],
        "First response.",
        1
      ),
      turn(
        ~U[2026-08-07 02:00:07.000000Z],
        ~U[2026-08-07 02:00:08.000000Z],
        ~U[2026-08-07 02:00:09.000000Z],
        ~U[2026-08-07 02:00:10.000000Z],
        "Second response.",
        2
      )
    ]
  end

  defp turn(
         planned_at,
         generated_at,
         publication_started_at,
         publication_completed_at,
         text,
         index
       ) do
    %Turn{
      planned_at: planned_at,
      generated_at: generated_at,
      publication_started_at: publication_started_at,
      publication_completed_at: publication_completed_at,
      generation_transport: fn :request ->
        send(self(), {:generation_transport, index})
        {:ok, text}
      end,
      publication_transport: fn :request ->
        send(self(), {:publication_transport, index})
        :ok
      end
    }
  end

  defp three_person_continuation do
    configuration = RuntimeFixture.responder_configuration()
    responder = configuration.personas.personas["responder"]

    third = %{
      responder
      | id: "third",
        display_name: "Third",
        prompt: "Reply using only supplied facts and conversation history."
    }

    binding = configuration.bindings.bindings["characters"]
    binding = %{binding | candidates: binding.candidates ++ [%{persona: third.id, weight: 1}]}

    configuration = %{
      configuration
      | personas: %PersonaCatalog{
          personas: Map.put(configuration.personas.personas, third.id, third)
        },
        bindings: %BindingCatalog{bindings: %{binding.id => binding}}
    }

    continuation = RuntimeFixture.responder_input(configuration)
    %{continuation | budget: %{continuation.budget | max_participants: 3}}
  end

  defp adapters do
    %Adapters{
      random: SequenceRandom,
      conversation_store: ConversationStore,
      provider: Provider,
      message_store: MessageStore,
      publication_start_store: PublicationStartStore,
      publisher: Publisher,
      publication_terminal_store: PublicationTerminalStore,
      cooldown_store: CooldownStore
    }
  end

  defp flush_mailbox do
    receive do
      _message -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end

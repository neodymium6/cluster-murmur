defmodule ClusterMurmur.Runtime.ResponderTurnCycleTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.ResponderTurnFinisher.Continuation
  alias ClusterMurmur.Persistence.{MessageRecord, PersonaCooldownRecord, PublicationAttemptRecord}
  alias ClusterMurmur.Runtime.ResponderTurnCycle
  alias ClusterMurmur.Runtime.ResponderTurnCycle.{Adapters, Input}
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @generated_at ~U[2026-08-07 02:00:04.000000Z]
  @publication_started_at ~U[2026-08-07 02:00:05.000000Z]
  @publication_completed_at ~U[2026-08-07 02:00:06.000000Z]

  defmodule ReplyRandom do
    def weighted_choice(_choices), do: {:ok, {:reply, "responder"}}
  end

  defmodule NoReplyRandom do
    def weighted_choice(_choices), do: {:ok, :no_reply}
  end

  defmodule ConversationStore do
    def claim_generation(waiting, persona_id) do
      send(self(), {:claim_generation, waiting, persona_id})

      {:ok,
       %{
         waiting
         | status: :generating,
           llm_call_count: waiting.llm_call_count + 1
       }}
    end

    def consume_generation(generating, persona_id) do
      send(self(), {:consume_generation, generating, persona_id})
      :ok
    end

    def confirm_completed(completed) do
      send(self(), {:confirm_completed, completed})
      :ok
    end

    def wait(active) do
      send(self(), {:wait, active})
      {:ok, %{active | status: :waiting}}
    end

    def complete(active, completed_at) do
      send(self(), {:complete, active, completed_at})
      {:ok, %{active | status: :completed, completed_at: completed_at}}
    end
  end

  defmodule Provider do
    def generate(request, _settings, transport) do
      send(self(), {:generate, request})
      transport.(:request)
    end
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
          discord_message_id: generated.discord_message_id,
          inserted_at: generated.inserted_at
        }
        |> Ecto.put_meta(state: :loaded)

      {:ok, {message, %{conversation | turn_count: conversation.turn_count + 1}}}
    end
  end

  defmodule PublicationStartStore do
    def start(_publication, message, _persona, _settings, started_at) do
      send(self(), {:start_publication, message, started_at})

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
      send(self(), {:publish, attempt, message})
      transport.(:request)

      case Process.get({__MODULE__, :outcome}, :success) do
        :success -> {:ok, "12345", %{attempt | status: :dispatching}}
        {:failed, reason} -> {:failed, reason, %{attempt | status: :dispatching}}
        :ambiguous -> {:ambiguous, :interrupted, %{attempt | status: :dispatching}}
      end
    end
  end

  defmodule PublicationTerminalStore do
    def succeed(dispatching, message, discord_message_id, completed_at) do
      send(self(), {:succeed_publication, dispatching, message, completed_at})

      attempt = %{
        dispatching
        | status: :succeeded,
          completed_at: completed_at,
          error_class: nil
      }

      {:ok, {attempt, %{message | discord_message_id: discord_message_id}}}
    end

    def fail(dispatching, reason, completed_at) do
      send(self(), {:fail_publication, dispatching, reason, completed_at})

      {:ok,
       %{
         dispatching
         | status: :failed,
           completed_at: completed_at,
           error_class: reason
       }}
    end

    def mark_ambiguous(dispatching, completed_at) do
      send(self(), {:mark_ambiguous, dispatching, completed_at})

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
      send(self(), {:record_spoken, persona_id, spoken_at, cooldown_until})

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
    :ok
  end

  test "runs one reply through publication and returns one waiting continuation" do
    input = input()

    assert {:continue, %Continuation{} = continuation} =
             ResponderTurnCycle.run(input, adapters(ReplyRandom))

    assert continuation.conversation.status == :waiting
    assert continuation.conversation.turn_count == 2
    assert continuation.conversation.llm_call_count == 2
    assert continuation.runtime.participants == ["caretaker", "responder"]

    assert continuation.current_cooldowns["responder"].last_spoken_at ==
             @publication_completed_at

    assert_receive {:claim_generation, _waiting, "responder"}
    assert_receive {:consume_generation, _generating, "responder"}
    assert_receive {:generate, request}
    assert request.persona["display_name"] == "Responder"
    assert_receive {:append_reserved, _generating, generated}
    assert generated.content == "A factual response."
    assert_receive {:start_publication, _message, @publication_started_at}
    assert_receive {:publish, _attempt, _message}
    assert_receive {:succeed_publication, _attempt, _message, @publication_completed_at}

    assert_receive {:record_spoken, "responder", @publication_completed_at,
                    ~U[2026-08-07 02:01:06.000000Z]}

    assert_receive {:wait, _active}
    refute_received {:complete, _active, _completed_at}

    inspected = inspect({input, continuation})
    refute inspected =~ "fake-token"
    refute inspected =~ "private fact"
  end

  test "closes a sampled no-reply without generation or publication" do
    assert {:ok, :no_reply, result} =
             input()
             |> ResponderTurnCycle.run(adapters(NoReplyRandom))

    assert result.outcome == :no_reply
    assert result.status == :dispatched
    assert_receive {:complete, completed, ~U[2026-08-07 02:00:03.000000Z]}
    assert completed.status == :waiting
    assert_receive {:confirm_completed, confirmed}
    assert confirmed.status == :completed

    refute_received {:claim_generation, _waiting, _persona_id}
    refute_received {:generate, _request}
    refute_received {:append_reserved, _conversation, _message}
    refute_received {:start_publication, _message, _started_at}
    refute_received {:publish, _attempt, _message}
    refute_received {:record_spoken, _persona_id, _spoken_at, _cooldown_until}
  end

  test "propagates one durable publication failure or ambiguity without cooldown or retry" do
    Process.put({Publisher, :outcome}, {:failed, :timeout})

    assert {:failed, :timeout, failed} =
             input()
             |> ResponderTurnCycle.run(adapters(ReplyRandom))

    assert failed.status == :failed
    assert_receive {:fail_publication, _attempt, :timeout, @publication_completed_at}
    refute_received {:record_spoken, _persona_id, _spoken_at, _cooldown_until}
    refute_received {:wait, _active}

    flush_mailbox()
    Process.put({Publisher, :outcome}, :ambiguous)

    assert {:ambiguous, :interrupted, ambiguous} =
             input()
             |> ResponderTurnCycle.run(adapters(ReplyRandom))

    assert ambiguous.status == :ambiguous
    assert_receive {:mark_ambiguous, _attempt, @publication_completed_at}
    refute_received {:record_spoken, _persona_id, _spoken_at, _cooldown_until}
    refute_received {:wait, _active}
  end

  test "rejects invalid fixed inputs and adapters before the durable selection" do
    valid = input()

    invalid_times = %{
      valid
      | publication_started_at: DateTime.add(@generated_at, -1, :second)
    }

    assert ResponderTurnCycle.run(invalid_times, adapters(ReplyRandom)) ==
             {:error, :invalid_responder_turn_cycle}

    assert ResponderTurnCycle.run(valid, %{adapters(ReplyRandom) | publisher: String}) ==
             {:error, :invalid_responder_turn_cycle}

    assert ResponderTurnCycle.run(
             %{
               valid
               | provider_settings: %{valid.provider_settings | reasoning_effort: :low}
             },
             adapters(ReplyRandom)
           ) == {:error, :invalid_responder_turn_cycle}

    assert ResponderTurnCycle.validate_runtime(
             %{valid | generated_at: :private_invalid_time},
             adapters(ReplyRandom)
           ) == {:error, :invalid_responder_turn_cycle}

    expiring = %{
      valid
      | continuation: %{
          valid.continuation
          | budget: %{valid.continuation.budget | max_duration_ms: 4_000}
        }
    }

    assert ResponderTurnCycle.run(expiring, adapters(ReplyRandom)) ==
             {:error, :invalid_responder_turn_cycle}

    refute_received {:complete, _active, _completed_at}
    refute_received {:claim_generation, _waiting, _persona_id}
    refute_received {:generate, _request}
    refute_received {:start_publication, _message, _started_at}
  end

  defp input do
    %Input{
      continuation: RuntimeFixture.responder_input(),
      provider_settings: RuntimeFixture.provider_settings(),
      generated_at: @generated_at,
      publication_started_at: @publication_started_at,
      publication_completed_at: @publication_completed_at,
      generation_transport: fn :request -> {:ok, "A factual response."} end,
      publication_transport: fn :request -> :ok end
    }
  end

  defp adapters(random) do
    %Adapters{
      random: random,
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

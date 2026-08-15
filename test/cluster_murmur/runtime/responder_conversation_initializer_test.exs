defmodule ClusterMurmur.Runtime.ResponderConversationInitializerTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.ConversationDefaults
  alias ClusterMurmur.Runtime.{ResponderConversationInitializer, ResponderConversationRunner}
  alias ClusterMurmur.Runtime.ResponderConversationInitializer.Input
  alias ClusterMurmur.Runtime.ResponderConversationRunner.Turn
  alias ClusterMurmur.TestSupport.RuntimeFixture

  @planned_at ~U[2026-08-07 02:00:03.000000Z]

  test "derives the exact first responder input from starter proof and configured policy" do
    initializer = input()

    assert {:ok, %ResponderConversationRunner.Input{} = runner} =
             ResponderConversationInitializer.initialize(initializer)

    projected = runner.continuation
    starter = initializer.continuation.recorded.published.message

    assert projected.continuation === initializer.continuation
    assert projected.configuration === initializer.configuration
    assert projected.starter_cooldowns === %{}
    assert projected.webhook_settings === initializer.webhook_settings
    assert projected.planned_at == @planned_at
    assert projected.no_reply_weight == 1.0

    assert projected.current_cooldowns == %{
             starter.persona_id => initializer.continuation.recorded.cooldown
           }

    assert projected.budget.max_turns == 3
    assert projected.budget.max_participants == 2
    assert projected.budget.max_duration_ms == 300_000
    assert projected.budget.max_llm_calls == 3
    refute projected.policy.allow_same_persona_consecutively
    assert projected.policy.allow_persona_reentry

    assert projected.conversation.status == :waiting
    assert projected.conversation.participants == [starter.persona_id]
    assert [message] = projected.conversation.messages
    assert message.content == starter.content
    assert message.discord_message_id == starter.discord_message_id
    assert runner.provider_settings === initializer.provider_settings
    assert runner.turns === initializer.turns

    inspected = inspect({initializer, runner})
    refute inspected =~ "fake-token"
    refute inspected =~ "private fact"
    refute inspected =~ starter.content
  end

  test "projects non-default bounded policy from the same proven configuration" do
    defaults = %{
      ConversationDefaults.default()
      | max_turns: 5,
        max_duration_ms: 600_000,
        max_llm_calls: 4,
        allow_same_persona_consecutively: true,
        allow_persona_reentry: false,
        no_reply_weight: 2.5
    }

    configuration = %{
      RuntimeFixture.responder_configuration()
      | conversation_defaults: defaults
    }

    assert {:ok, runner} =
             configuration
             |> input()
             |> ResponderConversationInitializer.initialize()

    projected = runner.continuation

    assert projected.budget.max_turns == 5
    assert projected.budget.max_duration_ms == 600_000
    assert projected.budget.max_llm_calls == 4
    assert projected.policy.allow_same_persona_consecutively
    refute projected.policy.allow_persona_reentry
    assert projected.no_reply_weight == 2.5
  end

  test "rejects forged policy, settings, continuation, and schedule correlations" do
    valid = input()
    [turn] = valid.turns

    invalid = [
      nil,
      Map.put(valid, :private, true),
      %{valid | continuation: nil},
      %{valid | starter_cooldowns: []},
      %{valid | webhook_settings: %{valid.webhook_settings | url: "https://example.invalid"}},
      %{
        valid
        | provider_settings: %{valid.provider_settings | timeout_ms: 1}
      },
      %{
        valid
        | provider_settings: %{valid.provider_settings | reasoning_effort: :low}
      },
      %{
        valid
        | configuration: %{
            valid.configuration
            | conversation_defaults: %{
                ConversationDefaults.default()
                | max_turns: 0
              }
          }
      },
      %{valid | turns: []},
      %{
        valid
        | turns: [
            %{turn | planned_at: ~U[2026-08-07 02:00:02.000000Z]}
          ]
      }
    ]

    for rejected <- invalid do
      assert ResponderConversationInitializer.initialize(rejected) ==
               {:error, :invalid_responder_conversation_initialization}
    end
  end

  defp input(configuration \\ RuntimeFixture.responder_configuration()) do
    source = RuntimeFixture.responder_input(configuration)

    %Input{
      continuation: source.continuation,
      configuration: source.configuration,
      starter_cooldowns: source.starter_cooldowns,
      webhook_settings: source.webhook_settings,
      provider_settings: RuntimeFixture.provider_settings(),
      turns: [turn()]
    }
  end

  defp turn do
    %Turn{
      planned_at: @planned_at,
      generated_at: ~U[2026-08-07 02:00:04.000000Z],
      publication_started_at: ~U[2026-08-07 02:00:05.000000Z],
      publication_completed_at: ~U[2026-08-07 02:00:06.000000Z],
      generation_transport: fn _request -> :unused end,
      publication_transport: fn _request -> :unused end
    }
  end
end

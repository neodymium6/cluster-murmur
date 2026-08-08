defmodule ClusterMurmur.Triggers.EventConversationIdentityTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.TestSupport.RuntimeFixture
  alias ClusterMurmur.Triggers.EventConversationIdentity

  @executed_at ~U[2026-08-07 02:00:00.000000Z]

  test "derives one redacted retry-stable identity from exact match facts" do
    configuration = RuntimeFixture.configuration()
    event = RuntimeFixture.event()
    trigger = configuration.triggers.triggers["failure-conversation"]

    assert {:ok, first} = EventConversationIdentity.derive(event, trigger, @executed_at)
    assert EventConversationIdentity.derive(event, trigger, @executed_at) == {:ok, first}
    assert String.starts_with?(first, "conversation-")
    assert byte_size(first) == 77
    refute first =~ event.id
    refute first =~ trigger.id

    changed_trigger = %{trigger | id: "other-failure-conversation"}
    assert {:ok, second} = EventConversationIdentity.derive(event, changed_trigger, @executed_at)
    refute second == first

    assert {:ok, third} =
             EventConversationIdentity.derive(
               event,
               trigger,
               DateTime.add(@executed_at, 1, :microsecond)
             )

    refute third == first
  end

  test "rejects invalid facts and execution before the event" do
    configuration = RuntimeFixture.configuration()
    event = RuntimeFixture.event()
    trigger = configuration.triggers.triggers["failure-conversation"]

    invalid = [
      {%{event | id: ""}, trigger, @executed_at},
      {event, %{trigger | id: ""}, @executed_at},
      {event, trigger, DateTime.add(event.occurred_at, -1, :microsecond)},
      {event, trigger, %{DateTime.add(@executed_at, 1) | time_zone: "UTC"}}
    ]

    for {candidate_event, candidate_trigger, executed_at} <- invalid do
      assert EventConversationIdentity.derive(candidate_event, candidate_trigger, executed_at) ==
               {:error, :invalid_event_conversation_identity}
    end
  end
end

defmodule ClusterMurmur.Conversations.BudgetEvaluatorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.{Budget, BudgetEvaluator, BudgetState, Conversation}

  @started_at ~U[2026-08-05 12:00:00.000000Z]

  test "projects remaining configured capacity" do
    conversation =
      conversation(
        turn_count: 1,
        llm_call_count: 2,
        participants: ["observer"]
      )

    assert {:ok,
            %BudgetState{
              open?: true,
              exhausted: [],
              turns_remaining: 2,
              participant_slots_remaining: 1,
              duration_remaining_ms: 240_000,
              llm_calls_remaining: 1
            }} =
             BudgetEvaluator.evaluate(
               conversation,
               budget(),
               DateTime.add(@started_at, 60, :second)
             )
  end

  test "clamps exhausted counters and reports every reached limit" do
    conversation =
      conversation(
        turn_count: 4,
        llm_call_count: 3,
        participants: ["observer", "operator"]
      )

    assert {:ok,
            %BudgetState{
              open?: false,
              exhausted: [:duration, :llm_calls, :participants, :turns],
              turns_remaining: 0,
              participant_slots_remaining: 0,
              duration_remaining_ms: 0,
              llm_calls_remaining: 0
            }} =
             BudgetEvaluator.evaluate(
               conversation,
               budget(),
               DateTime.add(@started_at, 301, :second)
             )
  end

  test "treats the exact duration deadline as exhausted" do
    deadline = DateTime.add(@started_at, 300, :second)

    assert {:ok, %BudgetState{open?: true, duration_remaining_ms: 1}} =
             BudgetEvaluator.evaluate(
               conversation(),
               budget(),
               DateTime.add(deadline, -1, :microsecond)
             )

    assert {:ok, %BudgetState{open?: false, exhausted: [:duration]}} =
             BudgetEvaluator.evaluate(conversation(), budget(), deadline)
  end

  test "marks terminal conversations closed regardless of remaining counters" do
    for status <- [:completed, :cancelled, :failed] do
      assert {:ok, %BudgetState{open?: false, exhausted: [:terminal]}} =
               BudgetEvaluator.evaluate(conversation(status: status), budget(), @started_at)
    end
  end

  test "a full participant set does not block an existing participant from continuing" do
    assert {:ok,
            %BudgetState{
              open?: true,
              exhausted: [:participants],
              participant_slots_remaining: 0
            }} =
             BudgetEvaluator.evaluate(
               conversation(participants: ["observer", "operator"]),
               budget(),
               @started_at
             )
  end

  test "rejects malformed conversations, budgets, and supplied instants" do
    valid_conversation = conversation()
    valid_budget = budget()

    rejected = [
      {nil, valid_budget, @started_at, :invalid_conversation},
      {valid_conversation, nil, @started_at, :invalid_conversation_budget},
      {valid_conversation, %{valid_budget | max_turns: 0}, @started_at,
       :invalid_conversation_budget},
      {valid_conversation, %{valid_budget | max_participants: 257}, @started_at,
       :invalid_conversation_budget},
      {valid_conversation, %{valid_budget | max_duration_ms: 365 * 86_400_000 + 1}, @started_at,
       :invalid_conversation_budget},
      {valid_conversation, Map.put(valid_budget, :private_value, "private"), @started_at,
       :invalid_conversation_budget},
      {valid_conversation, valid_budget, %{@started_at | time_zone: "UTC"}, :invalid_datetime},
      {valid_conversation, valid_budget, DateTime.add(@started_at, -1, :microsecond),
       :invalid_datetime}
    ]

    for {conversation, budget, now, reason} <- rejected do
      result = BudgetEvaluator.evaluate(conversation, budget, now)
      assert result == {:error, reason}
      refute inspect(result) =~ "private"
    end
  end

  test "budget inputs and capacity outputs do not expose conversation values" do
    private_conversation =
      conversation(
        id: "private-conversation",
        root_event_id: "private-event",
        participants: ["private-persona"]
      )

    assert {:ok, state} = BudgetEvaluator.evaluate(private_conversation, budget(), @started_at)

    refute inspect(budget()) =~ "max_turns"
    refute inspect(state) =~ "private"
  end

  defp budget do
    %Budget{
      max_turns: 3,
      max_participants: 2,
      max_duration_ms: 300_000,
      max_llm_calls: 3
    }
  end

  defp conversation(overrides \\ []) do
    struct!(
      Conversation,
      Keyword.merge(
        [
          id: "conversation-1",
          root_event_id: "event-1",
          status: :waiting,
          started_at: @started_at,
          last_message_at: nil,
          turn_count: 0,
          llm_call_count: 0,
          participants: [],
          messages: []
        ],
        overrides
      )
    )
  end
end

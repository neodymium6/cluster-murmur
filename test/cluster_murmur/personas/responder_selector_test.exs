defmodule ClusterMurmur.Personas.ResponderSelectorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Conversations.ReplyGateDecision
  alias ClusterMurmur.Personas.{ResponderCandidate, ResponderSelector}

  defmodule CapturingRandom do
    def weighted_choice(outcomes) do
      send(self(), {:weighted_choice, outcomes})
      {:ok, {:reply, "zeta"}}
    end
  end

  defmodule NoReplyRandom do
    def weighted_choice(_outcomes), do: {:ok, :no_reply}
  end

  defmodule RaisingRandom do
    def weighted_choice(_outcomes), do: raise("private random failure")
  end

  defmodule EmptyRandom do
    def weighted_choice(_outcomes), do: :empty
  end

  defmodule UnknownRandom do
    def weighted_choice(_outcomes), do: {:ok, {:reply, "private-unknown"}}
  end

  defmodule MalformedRandom do
    def weighted_choice(_outcomes), do: {:error, "private random failure"}
  end

  test "honors a probability-gate no reply without consuming later inputs" do
    assert ResponderSelector.select(decision(:no_reply), :private, :private, RaisingRandom) ==
             {:ok, :no_reply}
  end

  test "returns no reply without sampling when no positive reply exists" do
    assert ResponderSelector.select(decision(:reply), [], 1, RaisingRandom) ==
             {:ok, :no_reply}

    assert ResponderSelector.select(
             decision(:reply),
             [candidate("observer", 0.0)],
             1.0,
             RaisingRandom
           ) == {:ok, :no_reply}
  end

  test "samples stable positive responders plus explicit no reply exactly once" do
    candidates = [candidate("zeta", 3), candidate("zero", 0), candidate("alpha", 1)]

    assert ResponderSelector.select(decision(:reply), candidates, 2, CapturingRandom) ==
             {:ok, {:reply, "zeta"}}

    assert_received {:weighted_choice,
                     [{{:reply, "alpha"}, 1}, {{:reply, "zeta"}, 3}, {:no_reply, 2}]}

    refute_received {:weighted_choice, _outcomes}
  end

  test "accepts the weighted no-reply outcome" do
    assert ResponderSelector.select(
             decision(:reply),
             [candidate("observer", 1)],
             1,
             NoReplyRandom
           ) == {:ok, :no_reply}
  end

  test "rejects malformed gate decisions before using other inputs" do
    valid = decision(:reply)

    for rejected <- [
          nil,
          %{},
          %{valid | outcome: :unknown},
          Map.delete(valid, :outcome),
          Map.put(valid, :private_value, "private")
        ] do
      result = ResponderSelector.select(rejected, :private, :private, RaisingRandom)
      assert result == {:error, :invalid_reply_gate_decision}
      refute inspect(result) =~ "private"
    end
  end

  test "rejects malformed candidates and no-reply weights before sampling" do
    valid = candidate("private-persona", 1)

    rejected_candidates = [
      nil,
      %{},
      %{valid | persona_id: "invalid id"},
      %{valid | weight: -1},
      %{valid | binding_weight: :infinity},
      %{valid | weight: 2},
      Map.delete(valid, :reply_weight),
      Map.put(valid, :private_value, "private")
    ]

    for candidate <- rejected_candidates do
      result = ResponderSelector.select(decision(:reply), [candidate], 1, RaisingRandom)

      assert result in [
               {:error, :invalid_responder_candidate},
               {:error, :invalid_candidate_weight}
             ]

      refute inspect(result) =~ "private"
    end

    for weight <- [0, 0.0, -1, :infinity, Integer.pow(2, 1_024)] do
      assert ResponderSelector.select(decision(:reply), [valid], weight, RaisingRandom) ==
               {:error, :invalid_no_reply_weight}
    end
  end

  test "rejects duplicate, improper, oversized, and aggregate-overflow candidates" do
    valid = candidate("observer", 1)

    assert ResponderSelector.select(decision(:reply), [valid, valid], 1, RaisingRandom) ==
             {:error, :duplicate_responder_candidate}

    assert ResponderSelector.select(decision(:reply), [valid | :tail], 1, RaisingRandom) ==
             {:error, :invalid_responder_candidate}

    oversized = Enum.map(1..257, &candidate("persona-#{&1}", 1))

    assert ResponderSelector.select(decision(:reply), oversized, 1, RaisingRandom) ==
             {:error, :too_many_responder_candidates}

    overflow = [
      candidate("alpha", 1.7976931348623157e308),
      candidate("zeta", 1.7976931348623157e308)
    ]

    assert ResponderSelector.select(decision(:reply), overflow, 1, RaisingRandom) ==
             {:error, :invalid_candidate_weight}
  end

  test "rejects invalid random adapters and outcomes without exposing values" do
    candidates = [candidate("alpha", 1), candidate("zeta", 1)]

    for random <- [RaisingRandom, String, nil] do
      result = ResponderSelector.select(decision(:reply), candidates, 1, random)
      assert result == {:error, :invalid_random_source}
      refute inspect(result) =~ "private"
    end

    for random <- [EmptyRandom, UnknownRandom, MalformedRandom] do
      result = ResponderSelector.select(decision(:reply), candidates, 1, random)
      assert result == {:error, :invalid_random_value}
      refute inspect(result) =~ "private"
    end
  end

  defp decision(outcome), do: %ReplyGateDecision{outcome: outcome}

  defp candidate(persona_id, weight) do
    %ResponderCandidate{
      persona_id: persona_id,
      binding_weight: weight,
      interest_weight: 0,
      relationship_weight: 0,
      reply_weight: 0,
      weight: weight
    }
  end
end

defmodule ClusterMurmur.Personas.StarterSelectorTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Personas.{StarterCandidate, StarterSelector}

  defmodule CapturingRandom do
    def weighted_choice(candidates) do
      send(self(), {:weighted_choice, candidates})
      {:ok, "zeta"}
    end
  end

  defmodule RaisingRandom do
    def weighted_choice(_candidates), do: raise("private random failure")
  end

  defmodule EmptyRandom do
    def weighted_choice(_candidates), do: :empty
  end

  defmodule UnknownRandom do
    def weighted_choice(_candidates), do: {:ok, "private-unknown"}
  end

  defmodule MalformedRandom do
    def weighted_choice(_candidates), do: {:error, "private random failure"}
  end

  defmodule ZeroWeightRandom do
    def weighted_choice(_candidates), do: {:ok, "zero"}
  end

  test "does not sample empty or zero-total candidates" do
    assert StarterSelector.select([], RaisingRandom) == :none
    assert StarterSelector.select([candidate("observer", 0)], RaisingRandom) == :none
    assert StarterSelector.select([candidate("observer", 0.0)], RaisingRandom) == :none

    assert StarterSelector.select(
             [candidate("alpha", 0), candidate("zeta", 0)],
             RaisingRandom
           ) == :none
  end

  test "selects one positive candidate without sampling" do
    assert StarterSelector.select([candidate("observer", 2)], RaisingRandom) ==
             {:ok, "observer"}

    assert StarterSelector.select(
             [candidate("zero", 0.0), candidate("observer", 2)],
             RaisingRandom
           ) == {:ok, "observer"}
  end

  test "delegates exactly one stable weighted choice for multiple candidates" do
    assert StarterSelector.select(
             [candidate("zeta", 3), candidate("zero", 0.0), candidate("alpha", 1)],
             CapturingRandom
           ) == {:ok, "zeta"}

    assert_received {:weighted_choice, [{"alpha", 1}, {"zeta", 3}]}
    refute_received {:weighted_choice, _candidates}
  end

  test "rejects invalid random adapters and results without exposing values" do
    candidates = [candidate("alpha", 1), candidate("zeta", 1)]

    for random <- [RaisingRandom, String, nil] do
      result = StarterSelector.select(candidates, random)
      assert result == {:error, :invalid_random_source}
      refute inspect(result) =~ "private"
    end

    candidates_with_zero = [candidate("alpha", 1), candidate("zero", 0), candidate("zeta", 1)]

    for random <- [EmptyRandom, UnknownRandom, MalformedRandom] do
      result = StarterSelector.select(candidates, random)
      assert result == {:error, :invalid_random_value}
      refute inspect(result) =~ "private"
    end

    assert StarterSelector.select(candidates_with_zero, ZeroWeightRandom) ==
             {:error, :invalid_random_value}
  end

  test "rejects malformed candidate values before sampling" do
    valid = candidate("private-persona", 3)

    rejected = [
      nil,
      %{},
      %{valid | persona_id: "invalid id"},
      %{valid | weight: -1},
      %{valid | binding_weight: :infinity},
      %{valid | weight: 4},
      Map.delete(valid, :interest_weight),
      Map.put(valid, :unexpected_private_value, "private")
    ]

    for candidate <- rejected do
      result = StarterSelector.select([candidate], RaisingRandom)

      assert result in [
               {:error, :invalid_starter_candidate},
               {:error, :invalid_candidate_weight}
             ]

      refute inspect(result) =~ "private"
    end
  end

  test "rejects duplicate, improper, and oversized candidate collections" do
    valid = candidate("observer", 1)

    assert StarterSelector.select([valid, valid], RaisingRandom) ==
             {:error, :duplicate_starter_candidate}

    assert StarterSelector.select([valid | :tail], RaisingRandom) ==
             {:error, :invalid_starter_candidate}

    oversized = Enum.map(1..257, &candidate("persona-#{&1}", 1))

    assert StarterSelector.select(oversized, RaisingRandom) ==
             {:error, :too_many_starter_candidates}
  end

  test "rejects an aggregate weight outside the numeric boundary before sampling" do
    candidates = [
      candidate("alpha", 1.7976931348623157e308),
      candidate("zeta", 1.7976931348623157e308)
    ]

    assert StarterSelector.select(candidates, RaisingRandom) ==
             {:error, :invalid_candidate_weight}
  end

  defp candidate(persona_id, weight) do
    %StarterCandidate{
      persona_id: persona_id,
      binding_weight: weight,
      interest_weight: 0,
      spontaneous_weight: 0,
      weight: weight
    }
  end
end

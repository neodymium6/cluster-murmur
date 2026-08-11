defmodule ClusterMurmur.Runtime.SystemRandomTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Runtime.SystemRandom

  test "returns finite values in the required half-open unit interval" do
    for _sample <- 1..1_000 do
      value = SystemRandom.uniform()
      assert is_float(value)
      assert value >= 0.0
      assert value < 1.0
    end
  end

  test "returns the sole positive weighted choice without sampling ambiguity" do
    assert SystemRandom.weighted_choice([{:ignored, 0}, {:selected, 2.5}]) ==
             {:ok, :selected}
  end

  test "returns only one of the supplied positive choices" do
    for _sample <- 1..1_000 do
      assert {:ok, choice} =
               SystemRandom.weighted_choice([{:first, 1}, {:ignored, 0}, {:second, 3}])

      assert choice in [:first, :second]
    end
  end

  test "fails closed for empty, zero-weight, malformed, or oversized choices" do
    assert SystemRandom.weighted_choice([]) == :empty
    assert SystemRandom.weighted_choice([{:first, 0}, {:second, 0.0}]) == :empty
    assert SystemRandom.weighted_choice([{:invalid, -1}]) == :empty
    assert SystemRandom.weighted_choice([{:invalid, :weight}]) == :empty
    assert SystemRandom.weighted_choice([{:valid, 1} | :improper]) == :empty
    assert SystemRandom.weighted_choice(:private) == :empty

    oversized = Enum.map(1..257, &{&1, 1})
    assert SystemRandom.weighted_choice(oversized) == :empty
  end
end

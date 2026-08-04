defmodule ClusterMurmur.Config.ValueTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.Value

  test "accepts portable machine-readable IDs" do
    assert Value.id("observer") == {:ok, "observer"}
    assert Value.id("Observer-2_internal.v1") == {:ok, "Observer-2_internal.v1"}
  end

  test "rejects non-portable and non-string IDs" do
    invalid_values = [
      "",
      "-observer",
      " observer",
      "observer ",
      "example target",
      "観測者",
      "e" <> <<0x0301::utf8>>,
      "line\nbreak",
      "line" <> <<0x2028::utf8>> <> "separator",
      "paragraph" <> <<0x2029::utf8>> <> "separator",
      "right-to-left" <> <<0x202E::utf8>> <> "override",
      "zero" <> <<0x200B::utf8>> <> "width",
      <<0x034F::utf8>>,
      <<0x3164::utf8>>,
      <<0xFE0F::utf8>>,
      <<0xE0100::utf8>>,
      <<255>>,
      :observer,
      nil
    ]

    assert Enum.all?(invalid_values, fn value ->
             Value.id(value) == {:error, :invalid_id}
           end)
  end

  test "accepts only strictly positive integers for bounded counts" do
    assert Value.positive_integer(1) == {:ok, 1}
    assert Value.positive_integer(12) == {:ok, 12}

    for value <- [0, -1, 1.0, "1", nil] do
      assert Value.positive_integer(value) == {:error, :invalid_positive_integer}
    end
  end

  test "accepts probabilities within the inclusive range" do
    assert Value.probability(0) == {:ok, 0}
    assert Value.probability(0.25) == {:ok, 0.25}
    assert Value.probability(1) == {:ok, 1}

    for value <- [-0.01, 1.01, "0.5", nil] do
      assert Value.probability(value) == {:error, :invalid_probability}
    end
  end

  test "accepts non-negative weights without lossy numeric conversion" do
    large_integer = Integer.pow(10, 400)

    assert Value.weight(0) == {:ok, 0}
    assert Value.weight(2.5) == {:ok, 2.5}
    assert Value.weight(large_integer) == {:ok, large_integer}

    for value <- [-0.01, "1", nil] do
      assert Value.weight(value) == {:error, :invalid_weight}
    end
  end
end

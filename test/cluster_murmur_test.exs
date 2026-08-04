defmodule ClusterMurmurTest do
  use ExUnit.Case, async: true

  test "reports the project version" do
    expected = "VERSION" |> File.read!() |> String.trim()

    assert ClusterMurmur.version() == expected
  end
end

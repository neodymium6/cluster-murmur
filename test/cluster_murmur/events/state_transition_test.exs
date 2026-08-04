defmodule ClusterMurmur.Events.StateTransitionTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Events.StateTransition

  test "classifies every normalized state transition" do
    assert StateTransition.classify(:unknown, :healthy) == :no_event
    assert StateTransition.classify(:unknown, :unhealthy) == {:ok, "observation.failed"}
    assert StateTransition.classify(:healthy, :healthy) == :no_event
    assert StateTransition.classify(:healthy, :unhealthy) == {:ok, "observation.failed"}
    assert StateTransition.classify(:unhealthy, :unhealthy) == :no_event
    assert StateTransition.classify(:unhealthy, :healthy) == {:ok, "observation.recovered"}
  end
end

defmodule ClusterMurmur.Events.StateTransition do
  @moduledoc """
  Deterministically classifies a committed observation state transition.

  Debouncing is intentionally outside this module: callers pass only committed
  states after the configured consecutive-observation threshold is met.
  """

  @type state :: :unknown | :healthy | :unhealthy
  @type event_type :: String.t()

  @spec classify(state(), :healthy | :unhealthy) :: {:ok, event_type()} | :no_event
  def classify(:unknown, :healthy), do: :no_event
  def classify(:unknown, :unhealthy), do: {:ok, "observation.failed"}
  def classify(:healthy, :healthy), do: :no_event
  def classify(:healthy, :unhealthy), do: {:ok, "observation.failed"}
  def classify(:unhealthy, :unhealthy), do: :no_event
  def classify(:unhealthy, :healthy), do: {:ok, "observation.recovered"}
end

defmodule ClusterMurmur.Observations.Observation do
  @moduledoc """
  A normalized snapshot returned by a read-only observer.

  Observations describe current state. They never directly cause publication;
  state tracking and event extraction must happen first.
  """

  @enforce_keys [:source, :subject, :state, :observed_at]
  defstruct [:source, :subject, :state, :observed_at, facts: %{}, labels: %{}]

  @type state :: :healthy | :unhealthy

  @type t :: %__MODULE__{
          source: String.t(),
          subject: String.t(),
          state: state(),
          observed_at: DateTime.t(),
          facts: map(),
          labels: map()
        }
end

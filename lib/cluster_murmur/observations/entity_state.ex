defmodule ClusterMurmur.Observations.EntityState do
  @moduledoc """
  One bounded durable observation/debounce state for a source and subject.

  Facts and labels describe the latest observation. The pending state and
  consecutive count represent debounce progress; event classification remains
  a separate application decision.
  """

  @derive {Inspect, only: [:current_state, :pending_state, :consecutive_count]}
  @enforce_keys [
    :source,
    :subject,
    :current_state,
    :pending_state,
    :consecutive_count,
    :last_observed_at,
    :last_changed_at,
    :facts,
    :labels
  ]
  defstruct [
    :source,
    :subject,
    :current_state,
    :pending_state,
    :consecutive_count,
    :last_observed_at,
    :last_changed_at,
    :facts,
    :labels
  ]

  @type committed_state :: :unknown | :healthy | :unhealthy
  @type observed_state :: :healthy | :unhealthy

  @type t :: %__MODULE__{
          source: String.t(),
          subject: String.t(),
          current_state: committed_state(),
          pending_state: observed_state() | nil,
          consecutive_count: non_neg_integer(),
          last_observed_at: DateTime.t(),
          last_changed_at: DateTime.t() | nil,
          facts: map(),
          labels: map()
        }
end

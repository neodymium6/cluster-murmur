defmodule ClusterMurmur.Events.Event do
  @moduledoc """
  An immutable fact that application code extracted from observations or a
  bounded trigger.
  """

  @enforce_keys [:id, :type, :source, :occurred_at]
  defstruct [
    :id,
    :type,
    :source,
    :subject,
    :group,
    :severity,
    :previous,
    :current,
    :occurred_at,
    :observed_at,
    :dedupe_key,
    :correlation_key,
    facts: %{},
    labels: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          source: String.t(),
          subject: String.t() | nil,
          group: String.t() | nil,
          severity: String.t() | nil,
          previous: term(),
          current: term(),
          occurred_at: DateTime.t(),
          observed_at: DateTime.t() | nil,
          dedupe_key: String.t() | nil,
          correlation_key: String.t() | nil,
          facts: map(),
          labels: map()
        }
end

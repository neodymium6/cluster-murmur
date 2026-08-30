defmodule ClusterMurmur.Ingestion.EventEnvelope do
  @moduledoc """
  One normalized external event before application-owned identity projection.

  The envelope cannot select a trigger, persona, prompt, provider, publisher,
  tool, endpoint, or credential.
  """

  @derive {Inspect, only: [:type, :source, :group, :severity, :occurred_at]}
  @enforce_keys [
    :idempotency_key,
    :type,
    :source,
    :subject,
    :group,
    :severity,
    :occurred_at,
    :facts,
    :labels
  ]
  defstruct [
    :idempotency_key,
    :type,
    :source,
    :subject,
    :group,
    :severity,
    :occurred_at,
    :facts,
    :labels
  ]

  @type scalar :: nil | boolean() | number() | String.t()

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          type: String.t(),
          source: String.t(),
          subject: String.t(),
          group: String.t(),
          severity: String.t(),
          occurred_at: DateTime.t(),
          facts: %{optional(String.t()) => scalar()},
          labels: %{optional(String.t()) => String.t()}
        }
end

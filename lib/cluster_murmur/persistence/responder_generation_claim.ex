defmodule ClusterMurmur.Persistence.ResponderGenerationClaim do
  @moduledoc """
  Redacted durable single-use binding between one conversation turn and its sampled responder.
  """

  use Ecto.Schema

  @derive {Inspect, only: []}
  @primary_key {:conversation_id, :string, autogenerate: false, redact: true}

  schema "responder_generation_claims" do
    field :persona_id, :string, redact: true
    field :turn_count, :integer, redact: true
    field :llm_call_count, :integer, redact: true
  end

  @type t :: %__MODULE__{
          conversation_id: String.t() | nil,
          persona_id: String.t() | nil,
          turn_count: non_neg_integer() | nil,
          llm_call_count: non_neg_integer() | nil
        }
end

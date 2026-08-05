defmodule ClusterMurmur.Messages.Message do
  @moduledoc """
  One bounded generated message and its optional publication identity.
  """

  @derive {Inspect, only: [:origin]}
  @enforce_keys [:conversation_id, :persona_id, :origin, :content, :inserted_at]
  defstruct [
    :conversation_id,
    :persona_id,
    :origin,
    :content,
    :discord_message_id,
    :inserted_at
  ]

  @type origin :: :llm | :fallback
  @type t :: %__MODULE__{
          conversation_id: String.t(),
          persona_id: String.t(),
          origin: origin(),
          content: String.t(),
          discord_message_id: String.t() | nil,
          inserted_at: DateTime.t()
        }
end

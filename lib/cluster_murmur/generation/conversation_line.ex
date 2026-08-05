defmodule ClusterMurmur.Generation.ConversationLine do
  @moduledoc """
  Redacted chronological conversation-history line for generation context.
  """

  @derive {Inspect, only: [:inserted_at]}
  @enforce_keys [:speaker, :content, :inserted_at]
  defstruct [:speaker, :content, :inserted_at]

  @type t :: %__MODULE__{
          speaker: String.t(),
          content: String.t(),
          inserted_at: DateTime.t()
        }
end

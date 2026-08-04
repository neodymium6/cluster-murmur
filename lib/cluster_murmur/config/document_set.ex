defmodule ClusterMurmur.Config.DocumentSet do
  @moduledoc """
  A validated manifest and its decoded, categorized source documents.

  Category-specific structural and semantic validation happens after this
  bounded input stage.
  """

  alias ClusterMurmur.Config.{LoadedDocument, Manifest}

  @derive {Inspect, only: [:manifest]}
  @enforce_keys [:manifest, :documents]
  defstruct [:manifest, :documents]

  @type documents :: %{
          required(:event_groups) => [LoadedDocument.t()],
          required(:personas) => [LoadedDocument.t()],
          required(:bindings) => [LoadedDocument.t()],
          required(:triggers) => [LoadedDocument.t()],
          required(:routing) => [LoadedDocument.t()]
        }

  @type t :: %__MODULE__{manifest: Manifest.t(), documents: documents()}
end

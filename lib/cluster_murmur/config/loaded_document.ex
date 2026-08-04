defmodule ClusterMurmur.Config.LoadedDocument do
  @moduledoc """
  One decoded included document and its canonical source path.

  The document has passed only the generic bounded YAML decoder. Its path and
  contents are omitted from inspection because both may reveal deployment
  details.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:path, :document]
  defstruct [:path, :document]

  @type t :: %__MODULE__{path: Path.t(), document: map()}
end

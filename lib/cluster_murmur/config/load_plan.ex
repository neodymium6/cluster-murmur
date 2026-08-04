defmodule ClusterMurmur.Config.LoadPlan do
  @moduledoc """
  A validated top-level manifest and its resolved configuration files.

  Creating a load plan does not decode or validate the included documents.
  The canonical paths remain grouped by category for those later stages.
  """

  alias ClusterMurmur.Config.Manifest

  @enforce_keys [:manifest, :files]
  defstruct [:manifest, :files]

  @type files :: %{
          required(:event_groups) => [Path.t()],
          required(:personas) => [Path.t()],
          required(:bindings) => [Path.t()],
          required(:triggers) => [Path.t()],
          required(:routing) => [Path.t()]
        }

  @type t :: %__MODULE__{manifest: Manifest.t(), files: files()}
end

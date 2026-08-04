defmodule ClusterMurmur.Personas.Binding do
  @moduledoc """
  Immutable configuration that maps one event group to weighted personas.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:id, :group, :candidates]
  defstruct [:id, :group, :candidates]

  @type candidate :: %{required(:persona) => String.t(), required(:weight) => number()}
  @type t :: %__MODULE__{
          id: String.t(),
          group: String.t(),
          candidates: [candidate()]
        }
end

defmodule ClusterMurmur.Personas.Persona do
  @moduledoc """
  Immutable persona configuration used for selection and expression.

  A persona is data, not an independently supervised process.
  """

  @enforce_keys [:id, :display_name]
  defstruct [
    :id,
    :display_name,
    :avatar,
    :prompt,
    :enabled,
    interests: %{},
    behavior: %{},
    relationships: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          avatar: String.t() | nil,
          prompt: String.t() | nil,
          enabled: boolean() | nil,
          interests: map(),
          behavior: map(),
          relationships: map(),
          metadata: map()
        }
end

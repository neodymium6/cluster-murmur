defmodule ClusterMurmur.Events.Matcher do
  @moduledoc """
  A bounded conjunction of declarative event predicates.

  Matchers are immutable application data. Evaluating them is deterministic
  domain logic and never delegates expressions or field access to an LLM.
  """

  defmodule Predicate do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:field, :operator]
    defstruct [:field, :operator, :value, values: []]

    @type operator ::
            :equals | :not_equals | :in | :exists | :greater_than | :less_than
    @type scalar :: nil | boolean() | number() | String.t()
    @type t :: %__MODULE__{
            field: String.t(),
            operator: operator(),
            value: scalar() | nil,
            values: [scalar()]
          }
  end

  @derive {Inspect, only: []}
  @enforce_keys [:predicates]
  defstruct [:predicates]

  @type t :: %__MODULE__{predicates: [Predicate.t()]}
end

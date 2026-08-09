defmodule ClusterMurmur.Persistence.ScheduleStateRetirement do
  @moduledoc false

  @derive {Inspect, only: [:retired_count, :saturated?]}
  @enforce_keys [:retired_count, :saturated?]
  defstruct [:retired_count, :saturated?]

  @type t :: %__MODULE__{
          retired_count: non_neg_integer(),
          saturated?: boolean()
        }
end

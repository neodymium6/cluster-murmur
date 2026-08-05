defmodule ClusterMurmur.Observations.DebouncePolicy do
  @moduledoc "Bounded consecutive-observation thresholds for committed health changes."

  @enforce_keys [:healthy_threshold, :unhealthy_threshold]
  defstruct [:healthy_threshold, :unhealthy_threshold]

  @type t :: %__MODULE__{
          healthy_threshold: pos_integer(),
          unhealthy_threshold: pos_integer()
        }
end

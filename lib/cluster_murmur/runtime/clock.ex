defmodule ClusterMurmur.Runtime.Clock do
  @moduledoc "A narrow clock contract for runtime scheduling."

  @callback utc_now() :: DateTime.t()
end

defmodule ClusterMurmur.DomainLimits do
  @moduledoc false

  @max_id_bytes 16 * 1_024
  @max_interval_ms 365 * 86_400_000
  @max_safe_integer 9_007_199_254_740_991
  @max_float 1.7976931348623157e308

  def max_id_bytes, do: @max_id_bytes
  def max_interval_ms, do: @max_interval_ms
  def max_safe_integer, do: @max_safe_integer
  def max_float, do: @max_float
end

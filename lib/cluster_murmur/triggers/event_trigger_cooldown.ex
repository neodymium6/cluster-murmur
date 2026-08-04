defmodule ClusterMurmur.Triggers.EventTriggerCooldown do
  @moduledoc """
  Purely evaluates one event trigger's durable cooldown projection.

  The caller supplies canonical UTC instants. This module neither reads a
  clock nor persists, selects, or executes anything.
  """

  alias ClusterMurmur.DateTimeValidator
  alias ClusterMurmur.Triggers.{EventTrigger, EventTriggerValidator}

  @type decision :: {:eligible, DateTime.t()} | {:skip, :cooldown}
  @type error :: :invalid_datetime | :invalid_trigger | :invalid_trigger_matcher

  @doc "Returns an active-cooldown skip or the next cooldown deadline for an eligible trigger."
  @spec evaluate(term(), term(), term()) :: {:ok, decision()} | {:error, error()}
  def evaluate(%EventTrigger{} = trigger, cooldown_until, now) do
    with :ok <- EventTriggerValidator.validate(trigger),
         :ok <- validate_datetime(now),
         :ok <- validate_optional_datetime(cooldown_until) do
      decide(trigger, cooldown_until, now)
    end
  rescue
    _error -> {:error, :invalid_datetime}
  catch
    _kind, _reason -> {:error, :invalid_datetime}
  end

  def evaluate(trigger, _cooldown_until, _now) do
    case EventTriggerValidator.validate(trigger) do
      {:error, reason} -> {:error, reason}
      :ok -> {:error, :invalid_trigger}
    end
  end

  defp decide(trigger, cooldown_until, now) do
    if active_cooldown?(cooldown_until, now) do
      {:ok, {:skip, :cooldown}}
    else
      next_cooldown_until = DateTime.add(now, trigger.cooldown_ms * 1_000, :microsecond)

      case validate_datetime(next_cooldown_until) do
        :ok -> {:ok, {:eligible, next_cooldown_until}}
        {:error, :invalid_datetime} -> {:error, :invalid_datetime}
      end
    end
  end

  defp active_cooldown?(nil, _now), do: false

  defp active_cooldown?(%DateTime{} = cooldown_until, now),
    do: DateTime.compare(cooldown_until, now) == :gt

  defp validate_optional_datetime(nil), do: :ok
  defp validate_optional_datetime(datetime), do: validate_datetime(datetime)

  defp validate_datetime(datetime), do: DateTimeValidator.validate_storage_utc(datetime)
end

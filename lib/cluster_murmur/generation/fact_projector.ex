defmodule ClusterMurmur.Generation.FactProjector do
  @moduledoc """
  Projects an application-validated event into fixed allowlisted prompt facts.
  """

  alias ClusterMurmur.Events.Event
  alias ClusterMurmur.Events.Validator, as: EventValidator
  alias ClusterMurmur.Config.Presentation
  alias ClusterMurmur.Generation.{FactProjection, FactProjectionValidator}

  @type error :: :invalid_event | :invalid_fact_projection

  @doc "Returns one validated fact projection without event routing metadata."
  @spec project(term()) :: {:ok, FactProjection.t()} | {:error, error()}
  def project(event), do: project(event, Presentation.default())

  @doc "Returns one validated fact projection in the selected presentation timezone."
  @spec project(term(), term()) :: {:ok, FactProjection.t()} | {:error, error()}
  def project(event, presentation) do
    with :ok <- EventValidator.validate(event),
         :ok <- Presentation.validate(presentation),
         projection <- build(event, presentation),
         :ok <- FactProjectionValidator.validate(projection) do
      {:ok, projection}
    end
  rescue
    _error -> {:error, :invalid_fact_projection}
  catch
    _kind, _reason -> {:error, :invalid_fact_projection}
  end

  defp build(%Event{} = event, %Presentation{} = presentation) do
    %FactProjection{
      event_type: event.type,
      subject: event.subject,
      group: event.group,
      severity: event.severity,
      previous_state: event.previous,
      current_state: event.current,
      details: event.facts,
      occurred_at: event.occurred_at,
      occurred_at_timezone: presentation.timezone
    }
  end
end

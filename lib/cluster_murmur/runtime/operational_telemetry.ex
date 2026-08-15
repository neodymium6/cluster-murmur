defmodule ClusterMurmur.Runtime.OperationalTelemetry do
  @moduledoc """
  Emits fixed, bounded runtime metrics and redacted structured logs.

  Event names, measurements, metadata keys, component names, outcomes, and
  error classes are application-owned finite sets. Domain values and external
  payloads never cross this boundary.
  """

  require Logger

  alias ClusterMurmur.Discord.WebhookResponse
  alias ClusterMurmur.Generation.OpenAICompatibleResponse
  alias ClusterMurmur.Observers.MCPResponse

  @cycle_event [:cluster_murmur, :runtime, :cycle, :stop]
  @external_event [:cluster_murmur, :external, :request, :stop]
  @generation_event [:cluster_murmur, :generation, :decision]

  @cycle_errors %{
    poll: [nil, :invalid_cycle, :poll_failed],
    event_dispatch: [nil, :dispatch_failed, :invalid_cycle],
    recurring_schedule: [nil, :invalid_cycle],
    stochastic_schedule: [nil, :invalid_cycle],
    event_retention: [nil, :invalid_cycle, :retention_failed]
  }

  @external_sources [:discord_webhook, :model_provider, :observer_mcp]
  @generation_fallback_reasons [
    :blank_output,
    :character_limit_exceeded,
    :invalid_provider_output,
    :invalid_unicode,
    :provider_failure
  ]

  @doc "Records one completed bounded scheduler cycle."
  @spec cycle(atom(), integer(), atom() | nil) :: :ok
  def cycle(component, started_at, error_class) do
    with {:ok, outcome} <- cycle_outcome(component, error_class),
         {:ok, measurements} <- measurements(started_at) do
      metadata = %{component: component, outcome: outcome, error_class: error_class}
      emit(@cycle_event, measurements, metadata, "runtime cycle completed")
    else
      _invalid -> :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc "Records one fixed external request outcome and returns it unchanged."
  @spec external_request(term(), atom(), integer()) :: term()
  def external_request(result, source, started_at) do
    with true <- source in @external_sources,
         {:ok, outcome, error_class} <- external_outcome(source, result),
         {:ok, measurements} <- measurements(started_at) do
      metadata = %{component: source, outcome: outcome, error_class: error_class}
      emit(@external_event, measurements, metadata, "external request completed")
    end

    result
  rescue
    _error -> result
  catch
    _kind, _reason -> result
  end

  @doc "Records one fixed generation decision and returns it unchanged."
  @spec generation_decision(term()) :: term()
  def generation_decision(decision) do
    with {:ok, outcome, error_class} <- generation_outcome(decision) do
      metadata = %{component: :model_generation, outcome: outcome, error_class: error_class}
      emit(@generation_event, %{count: 1}, metadata, "generation decision completed")
    end

    decision
  rescue
    _error -> decision
  catch
    _kind, _reason -> decision
  end

  defp cycle_outcome(component, error_class) do
    case Map.fetch(@cycle_errors, component) do
      {:ok, errors} ->
        if error_class in errors,
          do: {:ok, if(error_class, do: :error, else: :ok)},
          else: {:error, :invalid_operational_telemetry}

      _invalid ->
        {:error, :invalid_operational_telemetry}
    end
  end

  defp external_outcome(:observer_mcp, {:ok, %MCPResponse{}}), do: {:ok, :ok, nil}

  defp external_outcome(:model_provider, {:ok, %OpenAICompatibleResponse{} = response}) do
    case OpenAICompatibleResponse.decode(response) do
      {:ok, _content} ->
        {:ok, :ok, nil}

      {:error, reason} when reason in [:authentication_failed, :invalid_request, :rate_limited] ->
        {:ok, :rejected, reason}

      {:error, reason}
      when reason in [:invalid_response, :timeout, :token_exhausted, :unavailable] ->
        {:ok, :error, reason}
    end
  end

  defp external_outcome(:discord_webhook, {:ok, %WebhookResponse{} = response}) do
    case WebhookResponse.decode(response) do
      {:ok, _message_id} ->
        {:ok, :ok, nil}

      {:error, reason} when reason in [:authentication_failed, :invalid_request, :rate_limited] ->
        {:ok, :rejected, reason}

      {:error, reason} when reason in [:invalid_response, :timeout, :unavailable] ->
        {:ok, :unknown, reason}
    end
  end

  defp external_outcome(:observer_mcp, {:error, :rejected, reason})
       when reason in [:authentication_failed, :invalid_request, :rate_limited],
       do: {:ok, :rejected, reason}

  defp external_outcome(source, {:error, :not_sent, reason})
       when source in [:model_provider, :observer_mcp] and reason in [:timeout, :unavailable],
       do: {:ok, :not_sent, reason}

  defp external_outcome(:discord_webhook, {:error, :not_sent, reason})
       when reason in [:invalid_request, :timeout, :unavailable],
       do: {:ok, :not_sent, reason}

  defp external_outcome(source, {:error, :invalid_response})
       when source in [:model_provider, :observer_mcp],
       do: {:ok, :error, :invalid_response}

  defp external_outcome(source, {:error, :outcome_unknown}) when source in @external_sources,
    do: {:ok, :unknown, :outcome_unknown}

  defp external_outcome(_source, _result), do: {:error, :invalid_operational_telemetry}

  defp generation_outcome({:llm, content}) when is_binary(content), do: {:ok, :accepted, nil}

  defp generation_outcome({:fallback, reason}) when reason in @generation_fallback_reasons,
    do: {:ok, :fallback, reason}

  defp generation_outcome(_decision), do: {:error, :invalid_operational_telemetry}

  defp measurements(started_at) when is_integer(started_at) do
    duration = System.monotonic_time() - started_at

    if duration >= 0,
      do: {:ok, %{count: 1, duration: duration}},
      else: {:error, :invalid_operational_telemetry}
  end

  defp measurements(_started_at), do: {:error, :invalid_operational_telemetry}

  defp emit(event, measurements, metadata, message) do
    :telemetry.execute(event, measurements, metadata)

    level = if metadata.outcome in [:accepted, :ok], do: :info, else: :warning

    Logger.log(level, message,
      component: metadata.component,
      outcome: metadata.outcome,
      error_class: metadata.error_class
    )

    :ok
  end
end

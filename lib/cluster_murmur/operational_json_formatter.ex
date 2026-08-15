defmodule ClusterMurmur.OperationalJSONFormatter do
  @moduledoc """
  Formats production logs as one allowlisted JSON object per line.

  Arbitrary messages and metadata are replaced rather than serialized. Only
  fixed operational messages and finite telemetry dimensions may be emitted.
  """

  @behaviour :logger_formatter

  @levels [:alert, :critical, :debug, :emergency, :error, :info, :notice, :warning]
  @messages [
    "external request completed",
    "generation decision completed",
    "runtime cycle completed"
  ]
  @components [
    :discord_webhook,
    :event_dispatch,
    :event_retention,
    :model_generation,
    :model_provider,
    :observer_mcp,
    :poll,
    :recurring_schedule,
    :stochastic_schedule
  ]
  @outcomes [:accepted, :error, :fallback, :not_sent, :ok, :rejected, :unknown]
  @error_classes [
    :authentication_failed,
    :blank_output,
    :character_limit_exceeded,
    :dispatch_failed,
    :invalid_cycle,
    :invalid_request,
    :invalid_response,
    :invalid_provider_output,
    :invalid_unicode,
    :outcome_unknown,
    :poll_failed,
    :provider_failure,
    :rate_limited,
    :retention_failed,
    :timeout,
    :token_exhausted,
    :unavailable
  ]

  @impl true
  def check_config(config) when is_map(config) and map_size(config) == 0, do: :ok
  def check_config(_config), do: {:error, :invalid_operational_json_formatter}

  @impl true
  def format(%{level: level, msg: message, meta: metadata}, config)
      when is_map(metadata) and is_map(config) do
    fields = [
      number_field("time", safe_time(metadata)),
      string_field("level", allowed(level, @levels, :unknown)),
      string_field("message", safe_message(message))
    ]

    fields =
      fields ++
        optional_field("component", metadata[:component], @components) ++
        optional_field("outcome", metadata[:outcome], @outcomes) ++
        optional_field("error_class", metadata[:error_class], @error_classes)

    ["{", Enum.intersperse(fields, ","), "}\n"]
  rescue
    _error -> fallback()
  catch
    _kind, _reason -> fallback()
  end

  def format(_event, _config), do: fallback()

  defp safe_time(%{time: time}) when is_integer(time) and time >= 0, do: time
  defp safe_time(_metadata), do: 0

  defp safe_message({:string, message}) when message in @messages, do: message
  defp safe_message(_message), do: "application event"

  defp optional_field(_key, nil, _allowed), do: []

  defp optional_field(key, value, allowed) do
    if value in allowed, do: [string_field(key, value)], else: []
  end

  defp allowed(value, allowed, fallback), do: if(value in allowed, do: value, else: fallback)

  defp number_field(key, value), do: [~s("#{key}":), Integer.to_string(value)]
  defp string_field(key, value), do: ~s("#{key}":"#{value}")

  defp fallback, do: ~s({"time":0,"level":"error","message":"logging failure"}\n)
end

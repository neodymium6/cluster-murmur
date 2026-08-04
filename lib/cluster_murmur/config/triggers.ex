defmodule ClusterMurmur.Config.Triggers do
  @moduledoc """
  Validates and combines version 1 trigger documents.

  Event triggers contain a bounded declarative matcher and one fixed
  start-conversation action. Schedule and stochastic triggers contain bounded
  timing policies and one fixed emit-event action. References remain unresolved
  until complete configuration assembly.
  """

  alias ClusterMurmur.Config.{Duration, EventMatcher, LoadedDocument, SchemaValidator, Value}
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Triggers.{ActiveHours, CronValidator}
  alias ClusterMurmur.Triggers.{EmittedEvent, EventTrigger, ScheduleTrigger, StochasticTrigger}

  @draft "http://json-schema.org/draft-07/schema#"
  @id_pattern "^[A-Za-z0-9][A-Za-z0-9._-]*$"
  @max_triggers 256
  @max_cron_bytes 256
  @max_timezone_bytes 128
  @max_interval_ms DomainLimits.max_interval_ms()
  @max_daily_limit 10_000
  @month_names ~w(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC)
  @weekday_names ~w(MON TUE WED THU FRI SAT SUN)

  @event_trigger_schema %{
    "type" => "object",
    "required" => ["id", "event", "action", "cooldown"],
    "additionalProperties" => false,
    "properties" => %{
      "id" => %{"type" => "string", "pattern" => @id_pattern},
      "event" => %{
        "type" => "object",
        "required" => ["match"],
        "additionalProperties" => false,
        "properties" => %{"match" => %{"type" => "object"}}
      },
      "action" => %{
        "type" => "object",
        "required" => ["type", "binding"],
        "additionalProperties" => false,
        "properties" => %{
          "type" => %{"type" => "string", "enum" => ["start_conversation"]},
          "binding" => %{"type" => "string", "pattern" => @id_pattern}
        }
      },
      "cooldown" => %{"type" => "string", "minLength" => 1, "maxLength" => 32}
    }
  }

  @schedule_trigger_schema %{
    "type" => "object",
    "required" => ["id", "schedule", "action"],
    "additionalProperties" => false,
    "properties" => %{
      "id" => %{"type" => "string", "pattern" => @id_pattern},
      "schedule" => %{
        "type" => "object",
        "required" => ["cron", "timezone"],
        "additionalProperties" => false,
        "properties" => %{
          "cron" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => @max_cron_bytes
          },
          "timezone" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => @max_timezone_bytes
          }
        }
      },
      "action" => %{
        "type" => "object",
        "required" => ["type", "event"],
        "additionalProperties" => false,
        "properties" => %{
          "type" => %{"type" => "string", "enum" => ["emit_event"]},
          "event" => %{
            "type" => "object",
            "required" => ["type", "group", "subject"],
            "additionalProperties" => false,
            "properties" => %{
              "type" => %{"type" => "string", "pattern" => @id_pattern},
              "group" => %{"type" => "string", "pattern" => @id_pattern},
              "subject" => %{"type" => "string", "pattern" => @id_pattern}
            }
          }
        }
      }
    }
  }

  @stochastic_trigger_schema %{
    "type" => "object",
    "required" => ["id", "stochastic", "action"],
    "additionalProperties" => false,
    "properties" => %{
      "id" => %{"type" => "string", "pattern" => @id_pattern},
      "stochastic" => %{
        "type" => "object",
        "required" => ["distribution", "mean_interval", "minimum_interval"],
        "additionalProperties" => false,
        "properties" => %{
          "distribution" => %{"type" => "string", "enum" => ["shifted_exponential"]},
          "mean_interval" => %{"type" => "string", "minLength" => 1, "maxLength" => 32},
          "minimum_interval" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => 32
          },
          "active_hours" => %{
            "type" => "object",
            "required" => ["start", "end", "timezone"],
            "additionalProperties" => false,
            "properties" => %{
              "start" => %{"type" => "string", "minLength" => 5, "maxLength" => 5},
              "end" => %{"type" => "string", "minLength" => 5, "maxLength" => 5},
              "timezone" => %{
                "type" => "string",
                "minLength" => 1,
                "maxLength" => @max_timezone_bytes
              }
            }
          },
          "daily_limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_daily_limit
          }
        }
      },
      "action" => %{
        "type" => "object",
        "required" => ["type", "event"],
        "additionalProperties" => false,
        "properties" => %{
          "type" => %{"type" => "string", "enum" => ["emit_event"]},
          "event" => %{
            "type" => "object",
            "required" => ["type", "group", "subject"],
            "additionalProperties" => false,
            "properties" => %{
              "type" => %{"type" => "string", "pattern" => @id_pattern},
              "group" => %{"type" => "string", "pattern" => @id_pattern},
              "subject" => %{"type" => "string", "pattern" => @id_pattern}
            }
          }
        }
      }
    }
  }

  @schema %{
    "$schema" => @draft,
    "type" => "object",
    "required" => ["triggers"],
    "additionalProperties" => false,
    "properties" => %{
      "triggers" => %{
        "type" => "array",
        "items" => %{
          "oneOf" => [@event_trigger_schema, @schedule_trigger_schema, @stochastic_trigger_schema]
        }
      }
    }
  }

  @derive {Inspect, only: []}
  @enforce_keys [:triggers]
  defstruct [:triggers]

  @type trigger :: EventTrigger.t() | ScheduleTrigger.t() | StochasticTrigger.t()
  @type t :: %__MODULE__{triggers: %{required(String.t()) => trigger()}}
  @type error ::
          :duplicate_trigger
          | :invalid_trigger_document
          | :invalid_trigger_schema
          | :too_many_triggers

  @doc "Validates and combines decoded trigger documents."
  @spec parse_documents(term()) :: {:ok, t()} | {:error, error()}
  def parse_documents(documents) when is_list(documents) do
    with {:ok, validator} <- compile_schema(),
         {:ok, matcher_validator} <- compile_matcher_schema(),
         {:ok, timezones} <- load_timezones() do
      parse_document_list(documents, validator, matcher_validator, timezones, %{}, 0)
    end
  end

  def parse_documents(_documents), do: {:error, :invalid_trigger_document}

  defp compile_schema do
    case SchemaValidator.compile(@schema) do
      {:ok, validator} -> {:ok, validator}
      {:error, _reason} -> {:error, :invalid_trigger_schema}
    end
  end

  defp compile_matcher_schema do
    case EventMatcher.compile() do
      {:ok, validator} -> {:ok, validator}
      {:error, _reason} -> {:error, :invalid_trigger_schema}
    end
  end

  defp load_timezones do
    case TimeZoneInfo.time_zones() do
      timezones when is_list(timezones) -> {:ok, MapSet.new(timezones)}
      _other -> {:error, :invalid_trigger_schema}
    end
  rescue
    _error -> {:error, :invalid_trigger_schema}
  catch
    _kind, _reason -> {:error, :invalid_trigger_schema}
  end

  defp parse_document_list(
         [],
         _validator,
         _matcher_validator,
         _timezones,
         triggers,
         _count
       ),
       do: {:ok, %__MODULE__{triggers: triggers}}

  defp parse_document_list(
         [%LoadedDocument{document: document} | documents],
         validator,
         matcher_validator,
         timezones,
         triggers,
         count
       ) do
    with :ok <- validate_document(validator, document),
         {:ok, triggers, count} <-
           collect_triggers(document["triggers"], matcher_validator, timezones, triggers, count) do
      parse_document_list(
        documents,
        validator,
        matcher_validator,
        timezones,
        triggers,
        count
      )
    end
  end

  defp parse_document_list(
         _documents,
         _validator,
         _matcher_validator,
         _timezones,
         _triggers,
         _count
       ),
       do: {:error, :invalid_trigger_document}

  defp validate_document(validator, document) do
    case SchemaValidator.validate(validator, document) do
      :ok -> :ok
      {:error, :schema_violation} -> {:error, :invalid_trigger_document}
      {:error, :invalid_schema_validator} -> {:error, :invalid_trigger_schema}
    end
  end

  defp collect_triggers(document_triggers, matcher_validator, timezones, triggers, count) do
    document_triggers
    |> Enum.sort_by(&Map.get(&1, "id"))
    |> Enum.reduce_while({:ok, triggers, count}, fn attributes, {:ok, triggers, count} ->
      collect_trigger(attributes, matcher_validator, timezones, triggers, count)
    end)
  end

  defp collect_trigger(attributes, matcher_validator, timezones, triggers, count) do
    id = attributes["id"]

    cond do
      Map.has_key?(triggers, id) ->
        {:halt, {:error, :duplicate_trigger}}

      count >= @max_triggers ->
        {:halt, {:error, :too_many_triggers}}

      true ->
        case build_trigger(attributes, matcher_validator, timezones) do
          {:ok, trigger} ->
            {:cont, {:ok, Map.put(triggers, trigger.id, trigger), count + 1}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end
  end

  defp build_trigger(%{"event" => _event} = attributes, matcher_validator, _timezones) do
    with {:ok, id} <- validate_id(attributes["id"]),
         {:ok, matcher} <- validate_matcher(attributes["event"]["match"], matcher_validator),
         {:ok, binding} <- validate_id(attributes["action"]["binding"]),
         {:ok, cooldown_ms} <- validate_cooldown(attributes["cooldown"]) do
      {:ok,
       %EventTrigger{
         id: id,
         matcher: matcher,
         action: :start_conversation,
         binding: binding,
         cooldown_ms: cooldown_ms
       }}
    end
  end

  defp build_trigger(%{"schedule" => schedule} = attributes, _matcher_validator, timezones) do
    with {:ok, id} <- validate_id(attributes["id"]),
         {:ok, cron} <- validate_cron(schedule["cron"]),
         {:ok, timezone} <- validate_timezone(schedule["timezone"], timezones),
         {:ok, event} <- validate_emitted_event(attributes["action"]["event"]) do
      {:ok,
       %ScheduleTrigger{
         id: id,
         cron: cron,
         timezone: timezone,
         action: :emit_event,
         event: event
       }}
    end
  end

  defp build_trigger(%{"stochastic" => stochastic} = attributes, _matcher_validator, timezones) do
    with {:ok, id} <- validate_id(attributes["id"]),
         {:ok, mean_interval_ms} <- validate_positive_interval(stochastic["mean_interval"]),
         {:ok, minimum_interval_ms} <-
           validate_positive_interval(stochastic["minimum_interval"]),
         true <- mean_interval_ms > minimum_interval_ms,
         {:ok, active_hours} <- validate_active_hours(stochastic["active_hours"], timezones),
         {:ok, daily_limit} <- validate_daily_limit(stochastic["daily_limit"]),
         true <- is_nil(daily_limit) or not is_nil(active_hours),
         {:ok, event} <- validate_emitted_event(attributes["action"]["event"]) do
      {:ok,
       %StochasticTrigger{
         id: id,
         distribution: :shifted_exponential,
         mean_interval_ms: mean_interval_ms,
         minimum_interval_ms: minimum_interval_ms,
         active_hours: active_hours,
         daily_limit: daily_limit,
         action: :emit_event,
         event: event
       }}
    else
      _failure -> {:error, :invalid_trigger_document}
    end
  end

  defp build_trigger(_attributes, _matcher_validator, _timezones),
    do: {:error, :invalid_trigger_document}

  defp validate_id(value) do
    case Value.id(value) do
      {:ok, id} -> {:ok, id}
      {:error, _reason} -> {:error, :invalid_trigger_document}
    end
  end

  defp validate_matcher(document, matcher_validator) do
    case EventMatcher.parse(document, matcher_validator) do
      {:ok, matcher} -> {:ok, matcher}
      {:error, :invalid_event_matcher} -> {:error, :invalid_trigger_document}
      {:error, :invalid_event_matcher_schema} -> {:error, :invalid_trigger_schema}
    end
  end

  defp validate_cooldown(value) do
    case Duration.parse(value) do
      {:ok, milliseconds} when milliseconds <= @max_interval_ms -> {:ok, milliseconds}
      {:error, _reason} -> {:error, :invalid_trigger_document}
      _too_large -> {:error, :invalid_trigger_document}
    end
  end

  defp validate_positive_interval(value) do
    case Duration.parse(value) do
      {:ok, milliseconds} when milliseconds > 0 and milliseconds <= @max_interval_ms ->
        {:ok, milliseconds}

      _failure ->
        {:error, :invalid_trigger_document}
    end
  end

  defp validate_active_hours(nil, _timezones), do: {:ok, nil}

  defp validate_active_hours(attributes, timezones) do
    with {:ok, start_minute} <- validate_clock_time(attributes["start"]),
         {:ok, end_minute} <- validate_clock_time(attributes["end"]),
         true <- start_minute != end_minute,
         {:ok, timezone} <- validate_timezone(attributes["timezone"], timezones) do
      {:ok,
       %ActiveHours{
         start_minute: start_minute,
         end_minute: end_minute,
         timezone: timezone
       }}
    else
      _failure -> {:error, :invalid_trigger_document}
    end
  end

  defp validate_clock_time(value) when is_binary(value) do
    case Regex.run(~r/\A([01][0-9]|2[0-3]):([0-5][0-9])\z/, value, capture: :all_but_first) do
      [hour, minute] -> {:ok, String.to_integer(hour) * 60 + String.to_integer(minute)}
      nil -> {:error, :invalid_trigger_document}
    end
  end

  defp validate_clock_time(_value), do: {:error, :invalid_trigger_document}

  defp validate_daily_limit(nil), do: {:ok, nil}

  defp validate_daily_limit(value)
       when is_integer(value) and value > 0 and value <= @max_daily_limit,
       do: {:ok, value}

  defp validate_daily_limit(_value), do: {:error, :invalid_trigger_document}

  defp validate_cron(value)
       when is_binary(value) and byte_size(value) <= @max_cron_bytes do
    fields = String.split(value, " ", trim: false)

    with true <- String.valid?(value),
         5 <- length(fields),
         false <- Enum.any?(fields, &(&1 == "")),
         true <- standard_cron_fields?(fields),
         {:ok, expression} <- parse_cron(value) do
      {:ok, expression}
    else
      _failure -> {:error, :invalid_trigger_document}
    end
  end

  defp validate_cron(_value), do: {:error, :invalid_trigger_document}

  defp standard_cron_fields?([minute, hour, day, month, weekday]) do
    Enum.all?([minute, hour, day], &numeric_cron_field?/1) and
      named_cron_field?(month, @month_names) and
      named_cron_field?(weekday, @weekday_names) and
      unambiguous_day_fields?(day, weekday)
  end

  defp standard_cron_fields?(_fields), do: false

  defp unambiguous_day_fields?(day, weekday), do: day == "*" or weekday == "*"

  defp numeric_cron_field?(field) do
    Regex.match?(~r/\A[0-9*,\/-]+\z/, field) and valid_step_divisors?(field)
  end

  defp named_cron_field?(field, allowed_names) do
    Regex.match?(~r/\A[0-9A-Za-z*,\/-]+\z/, field) and
      valid_step_divisors?(field) and
      Regex.scan(~r/[A-Za-z]+/, field)
      |> List.flatten()
      |> Enum.all?(&(String.upcase(&1) in allowed_names))
  end

  defp valid_step_divisors?(field) do
    field
    |> String.split(",")
    |> Enum.all?(fn component ->
      case String.split(component, "/") do
        [base] -> base != ""
        [base, divisor] -> base != "" and positive_decimal?(divisor)
        _parts -> false
      end
    end)
  end

  defp positive_decimal?(value) do
    Regex.match?(~r/\A[0-9]+\z/, value) and String.to_integer(value) > 0
  end

  defp parse_cron(value) do
    case Crontab.CronExpression.Parser.parse(value, false) do
      {:ok, expression} ->
        if CronValidator.valid?(expression),
          do: {:ok, expression},
          else: {:error, :invalid_trigger_document}

      {:error, _reason} ->
        {:error, :invalid_trigger_document}

      _other ->
        {:error, :invalid_trigger_document}
    end
  rescue
    _error -> {:error, :invalid_trigger_document}
  catch
    _kind, _reason -> {:error, :invalid_trigger_document}
  end

  defp validate_timezone(value, timezones)
       when is_binary(value) and byte_size(value) <= @max_timezone_bytes do
    if String.valid?(value) and MapSet.member?(timezones, value),
      do: {:ok, value},
      else: {:error, :invalid_trigger_document}
  end

  defp validate_timezone(_value, _timezones), do: {:error, :invalid_trigger_document}

  defp validate_emitted_event(attributes) do
    with {:ok, type} <- validate_id(attributes["type"]),
         {:ok, group} <- validate_id(attributes["group"]),
         {:ok, subject} <- validate_id(attributes["subject"]) do
      {:ok, %EmittedEvent{type: type, group: group, subject: subject}}
    end
  end
end

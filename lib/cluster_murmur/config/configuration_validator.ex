defmodule ClusterMurmur.Config.ConfigurationValidator do
  @moduledoc false

  alias ClusterMurmur.Config.{
    Bindings,
    Configuration,
    ConversationDefaults,
    EventPolicy,
    EventGroups,
    LLM,
    Personas
  }

  alias ClusterMurmur.Config.{Routing, StateTracking, Triggers, Value}
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Personas.{BindingValidator, Validator, Persona}
  alias ClusterMurmur.Triggers.{ActiveHours, CronValidator, EmittedEvent, EventTrigger}
  alias ClusterMurmur.Triggers.{EventTriggerValidator, ScheduleTrigger, StochasticTrigger}

  @configuration_keys Configuration.__struct__() |> Map.keys()
  @event_groups_keys EventGroups.__struct__() |> Map.keys()
  @personas_keys Personas.__struct__() |> Map.keys()
  @bindings_keys Bindings.__struct__() |> Map.keys()
  @triggers_keys Triggers.__struct__() |> Map.keys()
  @routing_keys Routing.__struct__() |> Map.keys()
  @schedule_keys ScheduleTrigger.__struct__() |> Map.keys()
  @stochastic_keys StochasticTrigger.__struct__() |> Map.keys()
  @active_hours_keys ActiveHours.__struct__() |> Map.keys()
  @emitted_event_keys EmittedEvent.__struct__() |> Map.keys()
  @group_keys [:id, :reply_probability]
  @max_values 256
  @max_timezone_bytes 128
  @max_daily_limit 10_000
  @max_interval_ms DomainLimits.max_interval_ms()

  @spec validate(term()) :: :ok | {:error, Configuration.error()}
  def validate(%Configuration{} = configuration) do
    with true <- exact_keys?(configuration, @configuration_keys),
         true <- configuration.version === 1,
         :ok <- validate_state_tracking(configuration.state_tracking),
         :ok <- validate_conversation_defaults(configuration.conversation_defaults),
         :ok <- validate_event_policy(configuration.event_policy),
         :ok <- validate_event_groups(configuration.event_groups),
         :ok <- validate_personas(configuration.personas),
         :ok <- validate_bindings(configuration.bindings),
         {:ok, timezones} <- load_timezones(),
         :ok <- validate_triggers(configuration.triggers, timezones),
         :ok <- validate_routing(configuration.routing),
         :ok <- validate_llm(configuration.llm),
         :ok <- validate_catalog_references(configuration),
         :ok <- validate_trigger_references(configuration) do
      :ok
    else
      {:error, _reason} = error -> error
      _failure -> {:error, :invalid_configuration}
    end
  rescue
    _error -> {:error, :invalid_configuration}
  catch
    _kind, _reason -> {:error, :invalid_configuration}
  end

  def validate(_configuration), do: {:error, :invalid_configuration}

  defp validate_state_tracking(state_tracking) do
    case StateTracking.validate(state_tracking) do
      :ok -> :ok
      {:error, :invalid_state_tracking_configuration} -> {:error, :invalid_configuration}
    end
  end

  defp validate_conversation_defaults(defaults) do
    case ConversationDefaults.validate(defaults) do
      :ok -> :ok
      {:error, :invalid_conversation_defaults} -> {:error, :invalid_configuration}
    end
  end

  defp validate_event_policy(policy) do
    case EventPolicy.validate(policy) do
      :ok -> :ok
      {:error, :invalid_event_policy} -> {:error, :invalid_configuration}
    end
  end

  defp validate_event_groups(%EventGroups{groups: groups} = event_groups) do
    if exact_keys?(event_groups, @event_groups_keys) and bounded_map?(groups) and
         Enum.all?(groups, &valid_group?/1),
       do: :ok,
       else: {:error, :invalid_configuration}
  end

  defp validate_event_groups(_event_groups), do: {:error, :invalid_configuration}

  defp valid_group?({id, %{id: group_id, reply_probability: probability} = group}) do
    id == group_id and exact_keys?(group, @group_keys) and match?({:ok, ^id}, Value.id(id)) and
      match?({:ok, ^probability}, Value.probability(probability))
  end

  defp valid_group?(_group), do: false

  defp validate_personas(%Personas{personas: personas} = configuration_personas) do
    if exact_keys?(configuration_personas, @personas_keys) and bounded_map?(personas) and
         Enum.all?(personas, &valid_persona?/1),
       do: :ok,
       else: {:error, :invalid_configuration}
  end

  defp validate_personas(_personas), do: {:error, :invalid_configuration}

  defp valid_persona?({id, %Persona{id: persona_id} = persona}),
    do: id == persona_id and Validator.validate(persona) == :ok

  defp valid_persona?(_persona), do: false

  defp validate_bindings(%Bindings{bindings: bindings} = configuration_bindings) do
    if exact_keys?(configuration_bindings, @bindings_keys) and bounded_map?(bindings) and
         Enum.all?(bindings, &valid_binding?/1),
       do: :ok,
       else: {:error, :invalid_configuration}
  end

  defp validate_bindings(_bindings), do: {:error, :invalid_configuration}

  defp valid_binding?({id, %{id: binding_id} = binding}),
    do: id == binding_id and BindingValidator.validate(binding) == :ok

  defp valid_binding?(_binding), do: false

  defp validate_triggers(%Triggers{triggers: triggers} = configuration_triggers, timezones) do
    if exact_keys?(configuration_triggers, @triggers_keys) and bounded_map?(triggers) and
         Enum.all?(triggers, &valid_trigger?(&1, timezones)),
       do: :ok,
       else: {:error, :invalid_configuration}
  end

  defp validate_triggers(_triggers, _timezones), do: {:error, :invalid_configuration}

  defp valid_trigger?({id, %EventTrigger{id: trigger_id} = trigger}, _timezones),
    do: id == trigger_id and EventTriggerValidator.validate(trigger) == :ok

  defp valid_trigger?({id, %ScheduleTrigger{id: trigger_id} = trigger}, timezones),
    do: id == trigger_id and valid_schedule_trigger?(trigger, timezones)

  defp valid_trigger?({id, %StochasticTrigger{id: trigger_id} = trigger}, timezones),
    do: id == trigger_id and valid_stochastic_trigger?(trigger, timezones)

  defp valid_trigger?(_trigger, _timezones), do: false

  defp valid_schedule_trigger?(trigger, timezones) do
    exact_keys?(trigger, @schedule_keys) and valid_id?(trigger.id) and
      CronValidator.valid?(trigger.cron) and valid_timezone?(trigger.timezone, timezones) and
      trigger.action == :emit_event and valid_emitted_event?(trigger.event)
  end

  defp valid_stochastic_trigger?(trigger, timezones) do
    exact_keys?(trigger, @stochastic_keys) and valid_id?(trigger.id) and
      trigger.distribution == :shifted_exponential and
      valid_interval?(trigger.mean_interval_ms) and
      valid_interval?(trigger.minimum_interval_ms) and
      trigger.mean_interval_ms > trigger.minimum_interval_ms and
      valid_active_hours?(trigger.active_hours, timezones) and
      valid_daily_limit?(trigger.daily_limit, trigger.active_hours) and
      trigger.action == :emit_event and valid_emitted_event?(trigger.event)
  end

  defp valid_active_hours?(nil, _timezones), do: true

  defp valid_active_hours?(%ActiveHours{} = active_hours, timezones) do
    exact_keys?(active_hours, @active_hours_keys) and
      is_integer(active_hours.start_minute) and active_hours.start_minute in 0..1439 and
      is_integer(active_hours.end_minute) and active_hours.end_minute in 0..1439 and
      active_hours.start_minute != active_hours.end_minute and
      valid_timezone?(active_hours.timezone, timezones)
  end

  defp valid_active_hours?(_active_hours, _timezones), do: false

  defp valid_daily_limit?(nil, _active_hours), do: true

  defp valid_daily_limit?(daily_limit, %ActiveHours{}),
    do: is_integer(daily_limit) and daily_limit in 1..@max_daily_limit

  defp valid_daily_limit?(_daily_limit, _active_hours), do: false

  defp valid_emitted_event?(%EmittedEvent{} = event) do
    exact_keys?(event, @emitted_event_keys) and valid_id?(event.type) and
      valid_id?(event.group) and valid_id?(event.subject)
  end

  defp valid_emitted_event?(_event), do: false

  defp validate_routing(%Routing{} = routing) do
    if exact_keys?(routing, @routing_keys) and
         match?({:ok, _name}, Value.environment_variable_name(routing.webhook_secret_file_env)),
       do: :ok,
       else: {:error, :invalid_configuration}
  end

  defp validate_routing(_routing), do: {:error, :invalid_configuration}

  defp validate_llm(llm) do
    case LLM.validate(llm) do
      :ok -> :ok
      {:error, :invalid_llm_configuration} -> {:error, :invalid_configuration}
    end
  end

  defp validate_catalog_references(configuration) do
    configuration.bindings.bindings
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {_id, binding}, :ok ->
      cond do
        not Map.has_key?(configuration.event_groups.groups, binding.group) ->
          {:halt, {:error, {:catalog, :unknown_binding_group}}}

        Enum.any?(binding.candidates, fn candidate ->
          not Map.has_key?(configuration.personas.personas, candidate.persona)
        end) ->
          {:halt, {:error, {:catalog, :unknown_binding_persona}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_trigger_references(configuration) do
    configuration.triggers.triggers
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn
      {_id, %EventTrigger{binding: binding}}, :ok ->
        continue_if_known(configuration.bindings.bindings, binding, :unknown_trigger_binding)

      {_id, %trigger{event: %{group: group}}}, :ok
      when trigger in [ScheduleTrigger, StochasticTrigger] ->
        continue_if_known(configuration.event_groups.groups, group, :unknown_trigger_group)
    end)
  end

  defp continue_if_known(values, id, error) do
    if Map.has_key?(values, id), do: {:cont, :ok}, else: {:halt, {:error, error}}
  end

  defp load_timezones do
    case TimeZoneInfo.time_zones() do
      timezones when is_list(timezones) -> {:ok, MapSet.new(timezones)}
      _other -> {:error, :invalid_configuration}
    end
  end

  defp valid_timezone?(timezone, timezones)
       when is_binary(timezone) and byte_size(timezone) in 1..@max_timezone_bytes,
       do: String.valid?(timezone) and MapSet.member?(timezones, timezone)

  defp valid_timezone?(_timezone, _timezones), do: false

  defp valid_interval?(interval),
    do: is_integer(interval) and interval in 1..@max_interval_ms

  defp valid_id?(id), do: match?({:ok, ^id}, Value.id(id))

  defp bounded_map?(values),
    do: is_map(values) and not is_struct(values) and map_size(values) <= @max_values

  defp exact_keys?(value, keys) when is_map(value),
    do: map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))
end

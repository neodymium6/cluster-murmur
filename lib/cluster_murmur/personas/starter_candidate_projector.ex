defmodule ClusterMurmur.Personas.StarterCandidateProjector do
  @moduledoc """
  Projects bounded, deterministic starter candidates from runtime facts.

  The projector validates every supplied capability, excludes disabled
  personas and active cooldowns, and calculates only non-negative configured
  weight components. It performs no persistence, clock reads, or sampling.
  """

  alias ClusterMurmur.{DateTimeValidator, DomainLimits}
  alias ClusterMurmur.Persistence.{PersonaCooldownRecord, PersonaCooldownRecordValidator}

  alias ClusterMurmur.Personas.{
    BindingValidator,
    Persona,
    StarterCandidate,
    Validator
  }

  @max_personas 256
  @max_cooldowns 256
  @max_float DomainLimits.max_float()

  @type error ::
          :duplicate_binding_candidate
          | :invalid_binding
          | :invalid_candidate_projection
          | :invalid_candidate_weight
          | :invalid_datetime
          | :invalid_persona_collection
          | :invalid_persona_cooldown_collection
          | :invalid_persona_cooldown_record
          | :too_many_candidates
          | :unknown_persona

  @doc "Projects eligible starters in stable persona-ID order."
  @spec project(term(), term(), term(), term()) ::
          {:ok, [StarterCandidate.t()]} | {:error, error()}
  def project(binding, personas, cooldowns, now) do
    with :ok <- BindingValidator.validate(binding),
         :ok <- validate_personas(personas),
         :ok <- validate_cooldowns(cooldowns),
         :ok <- DateTimeValidator.validate_storage_utc(now) do
      binding.candidates
      |> Enum.sort_by(& &1.persona)
      |> project_candidates(binding, personas, cooldowns, now, [])
    end
  rescue
    _error -> {:error, :invalid_candidate_projection}
  catch
    _kind, _reason -> {:error, :invalid_candidate_projection}
  end

  defp validate_personas(personas)
       when is_map(personas) and not is_struct(personas) and
              map_size(personas) <= @max_personas do
    Enum.reduce_while(personas, :ok, fn
      {persona_id, %Persona{id: stored_id} = persona}, :ok when persona_id == stored_id ->
        case Validator.validate(persona) do
          :ok -> {:cont, :ok}
          {:error, :invalid_persona} -> {:halt, {:error, :invalid_persona_collection}}
        end

      _entry, :ok ->
        {:halt, {:error, :invalid_persona_collection}}
    end)
  end

  defp validate_personas(_personas), do: {:error, :invalid_persona_collection}

  @doc "Validates one bounded exact persona cooldown collection."
  @spec validate_cooldowns(term()) :: :ok | {:error, error()}
  def validate_cooldowns(cooldowns)
      when is_map(cooldowns) and not is_struct(cooldowns) and
             map_size(cooldowns) <= @max_cooldowns do
    Enum.reduce_while(cooldowns, :ok, fn
      {persona_id, %PersonaCooldownRecord{persona_id: stored_id} = record}, :ok
      when persona_id == stored_id ->
        case PersonaCooldownRecordValidator.validate(record) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {_persona_id, %PersonaCooldownRecord{}}, :ok ->
        {:halt, {:error, :invalid_persona_cooldown_record}}

      _entry, :ok ->
        {:halt, {:error, :invalid_persona_cooldown_collection}}
    end)
  end

  def validate_cooldowns(_cooldowns), do: {:error, :invalid_persona_cooldown_collection}

  defp project_candidates([], _binding, _personas, _cooldowns, _now, candidates),
    do: {:ok, Enum.reverse(candidates)}

  defp project_candidates(
         [%{persona: persona_id, weight: binding_weight} | remaining],
         binding,
         personas,
         cooldowns,
         now,
         candidates
       ) do
    case Map.fetch(personas, persona_id) do
      {:ok, persona} ->
        project_persona(
          persona,
          binding,
          binding_weight,
          Map.get(cooldowns, persona_id),
          remaining,
          personas,
          cooldowns,
          now,
          candidates
        )

      :error ->
        {:error, :unknown_persona}
    end
  end

  defp project_persona(
         %Persona{enabled: false},
         binding,
         _binding_weight,
         _cooldown,
         remaining,
         personas,
         cooldowns,
         now,
         candidates
       ),
       do: project_candidates(remaining, binding, personas, cooldowns, now, candidates)

  defp project_persona(
         persona,
         binding,
         binding_weight,
         cooldown,
         remaining,
         personas,
         cooldowns,
         now,
         candidates
       ) do
    if active_cooldown?(cooldown, now) do
      project_candidates(remaining, binding, personas, cooldowns, now, candidates)
    else
      interest_weight = Map.get(persona.interests, binding.group, 0)
      spontaneous_weight = Map.get(persona.behavior, "spontaneous_weight", 0)

      with {:ok, weight} <- total_weight(binding_weight, interest_weight, spontaneous_weight) do
        candidate = %StarterCandidate{
          persona_id: persona.id,
          binding_weight: binding_weight,
          interest_weight: interest_weight,
          spontaneous_weight: spontaneous_weight,
          weight: weight
        }

        project_candidates(
          remaining,
          binding,
          personas,
          cooldowns,
          now,
          [candidate | candidates]
        )
      end
    end
  end

  defp active_cooldown?(nil, _now), do: false

  defp active_cooldown?(%PersonaCooldownRecord{cooldown_until: cooldown_until}, now),
    do: DateTime.compare(cooldown_until, now) == :gt

  defp total_weight(binding_weight, interest_weight, spontaneous_weight) do
    weight = binding_weight + interest_weight + spontaneous_weight

    if valid_weight?(weight),
      do: {:ok, weight},
      else: {:error, :invalid_candidate_weight}
  rescue
    _error -> {:error, :invalid_candidate_weight}
  end

  defp valid_weight?(weight) when is_integer(weight), do: weight >= 0 and weight <= @max_float

  defp valid_weight?(weight) when is_float(weight),
    do: weight == weight and weight >= 0 and weight <= @max_float

  defp valid_weight?(_weight), do: false
end

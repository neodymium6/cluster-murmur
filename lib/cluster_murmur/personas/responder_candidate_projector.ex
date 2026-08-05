defmodule ClusterMurmur.Personas.ResponderCandidateProjector do
  @moduledoc """
  Projects bounded responder candidates from validated runtime facts.

  The projector owns deterministic eligibility and configured weight
  components. It performs no reply-probability gate, no sampling, and no reads
  from storage or ambient clocks.
  """

  alias ClusterMurmur.Conversations.{BudgetEvaluator, Conversation}
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Persistence.{PersonaCooldownRecord, PersonaCooldownRecordValidator}

  alias ClusterMurmur.Personas.{
    BindingValidator,
    Persona,
    ResponderCandidate,
    ResponderPolicy,
    Validator
  }

  @policy_keys ResponderPolicy.__struct__() |> Map.keys()
  @policy_key_count length(@policy_keys)
  @max_personas 256
  @max_cooldowns 256
  @max_float DomainLimits.max_float()

  @type error ::
          :duplicate_binding_candidate
          | :invalid_binding
          | :invalid_candidate_weight
          | :invalid_conversation
          | :invalid_conversation_budget
          | :invalid_datetime
          | :invalid_persona_collection
          | :invalid_persona_cooldown_collection
          | :invalid_persona_cooldown_record
          | :invalid_responder_policy
          | :missing_previous_speaker
          | :too_many_candidates
          | :unknown_persona

  @doc "Projects eligible responders in stable persona-ID order."
  @spec project(term(), term(), term(), term(), term(), term(), term()) ::
          {:ok, [ResponderCandidate.t()]} | {:error, error()}
  def project(binding, personas, cooldowns, conversation, budget, now, policy) do
    with :ok <- BindingValidator.validate(binding),
         :ok <- validate_personas(personas),
         :ok <- validate_cooldowns(cooldowns),
         {:ok, budget_state} <- BudgetEvaluator.evaluate(conversation, budget, now),
         :ok <- validate_policy(policy),
         {:ok, previous_speaker} <- previous_speaker(conversation) do
      if budget_state.open? do
        binding.candidates
        |> Enum.sort_by(& &1.persona)
        |> project_candidates(
          binding,
          personas,
          cooldowns,
          conversation,
          budget_state.participant_slots_remaining,
          now,
          policy,
          previous_speaker,
          []
        )
      else
        {:ok, []}
      end
    end
  rescue
    _error -> {:error, :invalid_conversation}
  catch
    _kind, _reason -> {:error, :invalid_conversation}
  end

  defp validate_personas(personas)
       when is_map(personas) and not is_struct(personas) and map_size(personas) <= @max_personas do
    Enum.reduce_while(personas, :ok, fn
      {persona_id, %Persona{id: stored_id} = persona}, :ok when persona_id == stored_id ->
        if Validator.validate(persona) == :ok,
          do: {:cont, :ok},
          else: {:halt, {:error, :invalid_persona_collection}}

      _entry, :ok ->
        {:halt, {:error, :invalid_persona_collection}}
    end)
  end

  defp validate_personas(_personas), do: {:error, :invalid_persona_collection}

  defp validate_cooldowns(cooldowns)
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

  defp validate_cooldowns(_cooldowns), do: {:error, :invalid_persona_cooldown_collection}

  defp validate_policy(%ResponderPolicy{} = policy) do
    if map_size(policy) == @policy_key_count and
         Enum.all?(@policy_keys, &Map.has_key?(policy, &1)) and
         is_boolean(policy.allow_same_persona_consecutively) and
         is_boolean(policy.allow_persona_reentry),
       do: :ok,
       else: {:error, :invalid_responder_policy}
  end

  defp validate_policy(_policy), do: {:error, :invalid_responder_policy}

  defp previous_speaker(%Conversation{messages: []}), do: {:error, :missing_previous_speaker}

  defp previous_speaker(%Conversation{messages: messages}),
    do: {:ok, List.last(messages).persona_id}

  defp project_candidates(
         [],
         _binding,
         _personas,
         _cooldowns,
         _conversation,
         _slots,
         _now,
         _policy,
         _previous,
         candidates
       ),
       do: {:ok, Enum.reverse(candidates)}

  defp project_candidates(
         [%{persona: persona_id, weight: binding_weight} | remaining],
         binding,
         personas,
         cooldowns,
         conversation,
         participant_slots,
         now,
         policy,
         previous_speaker,
         candidates
       ) do
    case Map.fetch(personas, persona_id) do
      {:ok, persona} ->
        maybe_project(
          persona,
          binding,
          binding_weight,
          Map.get(cooldowns, persona_id),
          remaining,
          personas,
          cooldowns,
          conversation,
          participant_slots,
          now,
          policy,
          previous_speaker,
          candidates
        )

      :error ->
        {:error, :unknown_persona}
    end
  end

  defp maybe_project(
         persona,
         binding,
         binding_weight,
         cooldown,
         remaining,
         personas,
         cooldowns,
         conversation,
         participant_slots,
         now,
         policy,
         previous_speaker,
         candidates
       ) do
    interest_weight = Map.get(persona.interests, binding.group, 0)

    if eligible?(
         persona,
         interest_weight,
         cooldown,
         conversation,
         participant_slots,
         now,
         policy,
         previous_speaker
       ) do
      reply_weight = Map.get(persona.behavior, "reply_weight", 0)
      relationship_weight = 0

      with {:ok, weight} <-
             total_weight(binding_weight, interest_weight, relationship_weight, reply_weight) do
        candidate = %ResponderCandidate{
          persona_id: persona.id,
          binding_weight: binding_weight,
          interest_weight: interest_weight,
          relationship_weight: relationship_weight,
          reply_weight: reply_weight,
          weight: weight
        }

        continue(
          remaining,
          binding,
          personas,
          cooldowns,
          conversation,
          participant_slots,
          now,
          policy,
          previous_speaker,
          [candidate | candidates]
        )
      end
    else
      continue(
        remaining,
        binding,
        personas,
        cooldowns,
        conversation,
        participant_slots,
        now,
        policy,
        previous_speaker,
        candidates
      )
    end
  end

  defp continue(
         remaining,
         binding,
         personas,
         cooldowns,
         conversation,
         slots,
         now,
         policy,
         previous,
         candidates
       ) do
    project_candidates(
      remaining,
      binding,
      personas,
      cooldowns,
      conversation,
      slots,
      now,
      policy,
      previous,
      candidates
    )
  end

  defp eligible?(persona, interest_weight, cooldown, conversation, slots, now, policy, previous) do
    persona.enabled and interest_weight > 0 and not active_cooldown?(cooldown, now) and
      continuity_allowed?(persona.id, conversation, slots, policy, previous)
  end

  defp active_cooldown?(nil, _now), do: false

  defp active_cooldown?(%PersonaCooldownRecord{cooldown_until: deadline}, now),
    do: DateTime.compare(deadline, now) == :gt

  defp continuity_allowed?(persona_id, conversation, slots, policy, previous) do
    participated? = persona_id in conversation.participants

    cond do
      persona_id == previous ->
        policy.allow_same_persona_consecutively

      participated? ->
        policy.allow_persona_reentry

      true ->
        slots > 0
    end
  end

  defp total_weight(binding_weight, interest_weight, relationship_weight, reply_weight) do
    weight = binding_weight + interest_weight + relationship_weight + reply_weight

    if valid_weight?(weight),
      do: {:ok, weight},
      else: {:error, :invalid_candidate_weight}
  rescue
    _error -> {:error, :invalid_candidate_weight}
  end

  defp valid_weight?(weight) when is_integer(weight),
    do: weight >= 0 and weight <= @max_float

  defp valid_weight?(weight) when is_float(weight),
    do: weight == weight and weight >= 0 and weight <= @max_float

  defp valid_weight?(_weight), do: false
end

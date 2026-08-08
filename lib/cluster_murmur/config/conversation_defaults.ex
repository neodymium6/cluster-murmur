defmodule ClusterMurmur.Config.ConversationDefaults do
  @moduledoc """
  Validates immutable version 1 conversation and responder defaults.

  The normalized value projects only the application-owned budget and
  continuity policy consumed by responder orchestration. It contains no
  deployment settings, prompts, facts, or adapter capabilities.
  """

  alias ClusterMurmur.Config.Duration
  alias ClusterMurmur.Conversations.Budget
  alias ClusterMurmur.DomainLimits
  alias ClusterMurmur.Personas.ResponderPolicy

  @document_keys [
    "allow_persona_reentry",
    "allow_same_persona_consecutively",
    "max_duration",
    "max_llm_calls",
    "max_participants",
    "max_turns",
    "responder_selection"
  ]
  @selection_keys ["no_reply_weight", "random_jitter"]
  @struct_keys [
    :__struct__,
    :allow_persona_reentry,
    :allow_same_persona_consecutively,
    :max_duration_ms,
    :max_llm_calls,
    :max_participants,
    :max_turns,
    :no_reply_weight,
    :random_jitter
  ]
  @max_counter DomainLimits.max_safe_integer()
  @max_duration_ms DomainLimits.max_interval_ms()
  @max_float DomainLimits.max_float()
  @max_participants 256

  @derive {Inspect,
           only: [
             :max_turns,
             :max_participants,
             :max_duration_ms,
             :max_llm_calls,
             :allow_same_persona_consecutively,
             :allow_persona_reentry,
             :no_reply_weight,
             :random_jitter
           ]}
  @enforce_keys [
    :max_turns,
    :max_participants,
    :max_duration_ms,
    :max_llm_calls,
    :allow_same_persona_consecutively,
    :allow_persona_reentry,
    :no_reply_weight,
    :random_jitter
  ]
  defstruct [
    :max_turns,
    :max_participants,
    :max_duration_ms,
    :max_llm_calls,
    :allow_same_persona_consecutively,
    :allow_persona_reentry,
    :no_reply_weight,
    :random_jitter
  ]

  @type t :: %__MODULE__{
          max_turns: pos_integer(),
          max_participants: pos_integer(),
          max_duration_ms: pos_integer(),
          max_llm_calls: pos_integer(),
          allow_same_persona_consecutively: boolean(),
          allow_persona_reentry: boolean(),
          no_reply_weight: number(),
          random_jitter: number()
        }

  @type error :: :invalid_conversation_defaults

  @doc "Returns the fixed version 1 conversation defaults."
  @spec default() :: t()
  def default do
    %__MODULE__{
      max_turns: 3,
      max_participants: 2,
      max_duration_ms: 300_000,
      max_llm_calls: 3,
      allow_same_persona_consecutively: false,
      allow_persona_reentry: true,
      no_reply_weight: 1.0,
      random_jitter: 0.2
    }
  end

  @doc "Parses one exact decoded version 1 conversation-defaults mapping."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(document) when is_map(document) and not is_struct(document) do
    selection = document["responder_selection"]

    with true <- exact_map?(document, @document_keys),
         true <- is_map(selection) and not is_struct(selection),
         true <- exact_map?(selection, @selection_keys),
         {:ok, duration_ms} <- Duration.parse(document["max_duration"]),
         candidate = %__MODULE__{
           max_turns: document["max_turns"],
           max_participants: document["max_participants"],
           max_duration_ms: duration_ms,
           max_llm_calls: document["max_llm_calls"],
           allow_same_persona_consecutively: document["allow_same_persona_consecutively"],
           allow_persona_reentry: document["allow_persona_reentry"],
           no_reply_weight: selection["no_reply_weight"],
           random_jitter: selection["random_jitter"]
         },
         :ok <- validate(candidate) do
      {:ok, candidate}
    else
      _failure -> {:error, :invalid_conversation_defaults}
    end
  rescue
    _error -> {:error, :invalid_conversation_defaults}
  catch
    _kind, _reason -> {:error, :invalid_conversation_defaults}
  end

  def parse(_document), do: {:error, :invalid_conversation_defaults}

  @doc "Revalidates one exact normalized conversation-defaults value."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{} = defaults) do
    if exact_map?(defaults, @struct_keys) and valid_counter?(defaults.max_turns) and
         valid_participants?(defaults.max_participants) and
         valid_duration?(defaults.max_duration_ms) and valid_counter?(defaults.max_llm_calls) and
         is_boolean(defaults.allow_same_persona_consecutively) and
         is_boolean(defaults.allow_persona_reentry) and
         valid_positive_weight?(defaults.no_reply_weight) and
         valid_probability?(defaults.random_jitter),
       do: :ok,
       else: {:error, :invalid_conversation_defaults}
  rescue
    _error -> {:error, :invalid_conversation_defaults}
  catch
    _kind, _reason -> {:error, :invalid_conversation_defaults}
  end

  def validate(_defaults), do: {:error, :invalid_conversation_defaults}

  @doc "Projects the exact immutable budget consumed by responder orchestration."
  @spec to_budget(term()) :: {:ok, Budget.t()} | {:error, error()}
  def to_budget(defaults) do
    case validate(defaults) do
      :ok ->
        {:ok,
         %Budget{
           max_turns: defaults.max_turns,
           max_participants: defaults.max_participants,
           max_duration_ms: defaults.max_duration_ms,
           max_llm_calls: defaults.max_llm_calls
         }}

      {:error, :invalid_conversation_defaults} = error ->
        error
    end
  end

  @doc "Projects the exact immutable continuity policy for responder selection."
  @spec to_responder_policy(term()) :: {:ok, ResponderPolicy.t()} | {:error, error()}
  def to_responder_policy(defaults) do
    case validate(defaults) do
      :ok ->
        {:ok,
         %ResponderPolicy{
           allow_same_persona_consecutively: defaults.allow_same_persona_consecutively,
           allow_persona_reentry: defaults.allow_persona_reentry
         }}

      {:error, :invalid_conversation_defaults} = error ->
        error
    end
  end

  @doc false
  @spec to_document(term()) :: {:ok, map()} | {:error, error()}
  def to_document(defaults) do
    case validate(defaults) do
      :ok ->
        {:ok,
         %{
           "max_turns" => defaults.max_turns,
           "max_participants" => defaults.max_participants,
           "max_duration" => "#{defaults.max_duration_ms}ms",
           "max_llm_calls" => defaults.max_llm_calls,
           "allow_same_persona_consecutively" => defaults.allow_same_persona_consecutively,
           "allow_persona_reentry" => defaults.allow_persona_reentry,
           "responder_selection" => %{
             "no_reply_weight" => defaults.no_reply_weight,
             "random_jitter" => defaults.random_jitter
           }
         }}

      {:error, :invalid_conversation_defaults} = error ->
        error
    end
  end

  defp valid_counter?(value), do: is_integer(value) and value in 1..@max_counter
  defp valid_participants?(value), do: is_integer(value) and value in 1..@max_participants
  defp valid_duration?(value), do: is_integer(value) and value in 1..@max_duration_ms

  defp valid_positive_weight?(value) when is_integer(value),
    do: value > 0 and value <= @max_float

  defp valid_positive_weight?(value) when is_float(value),
    do: value == value and value > 0 and value <= @max_float

  defp valid_positive_weight?(_value), do: false

  defp valid_probability?(value) when is_number(value),
    do: value == value and value >= 0 and value <= 1

  defp valid_probability?(_value), do: false

  defp exact_map?(value, keys),
    do: map_size(value) == length(keys) and Enum.all?(keys, &Map.has_key?(value, &1))
end

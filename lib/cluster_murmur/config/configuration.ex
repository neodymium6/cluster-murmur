defmodule ClusterMurmur.Config.Configuration do
  @moduledoc """
  The complete validated version 1 startup configuration.

  Each category is validated before trigger references are resolved. The
  resulting value contains no deployment secrets and is safe to pass to later
  runtime construction boundaries without reopening configuration files.
  """

  alias ClusterMurmur.Config.{
    Bindings,
    Catalog,
    ConversationDefaults,
    DocumentSet,
    EventPolicy,
    EventGroups,
    LLM
  }

  alias ClusterMurmur.Config.{ConfigurationValidator, Personas, Routing, StateTracking, Triggers}
  alias ClusterMurmur.Triggers.{EventTrigger, ScheduleTrigger, StochasticTrigger}

  @default_conversation_defaults ConversationDefaults.default()
  @default_event_policy EventPolicy.default()

  @derive {Inspect, only: [:version]}
  @enforce_keys [
    :version,
    :event_groups,
    :personas,
    :bindings,
    :triggers,
    :routing,
    :llm,
    :state_tracking
  ]
  defstruct [
    :version,
    :event_groups,
    :personas,
    :bindings,
    :triggers,
    :routing,
    :llm,
    :state_tracking,
    conversation_defaults: @default_conversation_defaults,
    event_policy: @default_event_policy
  ]

  @type t :: %__MODULE__{
          version: 1,
          event_groups: EventGroups.t(),
          personas: Personas.t(),
          bindings: Bindings.t(),
          triggers: Triggers.t(),
          routing: Routing.t(),
          llm: LLM.t(),
          state_tracking: StateTracking.t(),
          conversation_defaults: ConversationDefaults.t(),
          event_policy: EventPolicy.t()
        }

  @type error ::
          :invalid_configuration
          | :unknown_trigger_binding
          | :unknown_trigger_group
          | {:catalog, Catalog.error()}
          | {:triggers, Triggers.error()}
          | {:routing, Routing.error()}

  @doc "Parses all categories and resolves every implemented reference."
  @spec parse(Path.t(), term()) :: {:ok, t()} | {:error, error()}
  def parse(config_path, %DocumentSet{} = document_set) do
    with {:ok, catalog} <- annotate(Catalog.parse(config_path, document_set), :catalog),
         documents = document_set.documents,
         {:ok, triggers} <-
           annotate(Triggers.parse_documents(documents.triggers), :triggers),
         {:ok, routing} <- annotate(Routing.parse_documents(documents.routing), :routing),
         :ok <- validate_trigger_references(triggers, catalog.bindings, catalog.event_groups) do
      {:ok,
       %__MODULE__{
         version: 1,
         event_groups: catalog.event_groups,
         personas: catalog.personas,
         bindings: catalog.bindings,
         triggers: triggers,
         routing: routing,
         llm: document_set.manifest.llm,
         state_tracking: document_set.manifest.state_tracking,
         conversation_defaults: document_set.manifest.conversation_defaults,
         event_policy: document_set.manifest.event_policy
       }}
    end
  end

  def parse(_config_path, _document_set), do: {:error, :invalid_configuration}

  @doc "Revalidates one exact complete runtime configuration and its references."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(configuration), do: ConfigurationValidator.validate(configuration)

  defp validate_trigger_references(triggers, bindings, event_groups) do
    triggers.triggers
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn
      {_id, %EventTrigger{binding: binding}}, :ok ->
        continue_if_known(bindings.bindings, binding, :unknown_trigger_binding)

      {_id, %trigger{event: %{group: group}}}, :ok
      when trigger in [ScheduleTrigger, StochasticTrigger] ->
        continue_if_known(event_groups.groups, group, :unknown_trigger_group)

      {_id, _trigger}, :ok ->
        {:halt, {:error, :invalid_configuration}}
    end)
  end

  defp continue_if_known(values, id, error) do
    if Map.has_key?(values, id), do: {:cont, :ok}, else: {:halt, {:error, error}}
  end

  defp annotate({:ok, value}, _category), do: {:ok, value}
  defp annotate({:error, reason}, category), do: {:error, {category, reason}}
end

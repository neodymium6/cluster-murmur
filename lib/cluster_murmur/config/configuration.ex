defmodule ClusterMurmur.Config.Configuration do
  @moduledoc """
  The complete validated version 1 startup configuration.

  Each category is validated before event-trigger binding references are
  resolved. The resulting value contains no deployment secrets and is safe to
  pass to later runtime construction boundaries without reopening configuration
  files.
  """

  alias ClusterMurmur.Config.{Bindings, Catalog, DocumentSet, EventGroups}
  alias ClusterMurmur.Config.{Personas, Routing, Triggers}

  @derive {Inspect, only: [:version]}
  @enforce_keys [:version, :event_groups, :personas, :bindings, :triggers, :routing]
  defstruct [:version, :event_groups, :personas, :bindings, :triggers, :routing]

  @type t :: %__MODULE__{
          version: 1,
          event_groups: EventGroups.t(),
          personas: Personas.t(),
          bindings: Bindings.t(),
          triggers: Triggers.t(),
          routing: Routing.t()
        }

  @type error ::
          :invalid_configuration
          | :unknown_trigger_binding
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
         :ok <- validate_trigger_references(triggers, catalog.bindings) do
      {:ok,
       %__MODULE__{
         version: 1,
         event_groups: catalog.event_groups,
         personas: catalog.personas,
         bindings: catalog.bindings,
         triggers: triggers,
         routing: routing
       }}
    end
  end

  def parse(_config_path, _document_set), do: {:error, :invalid_configuration}

  defp validate_trigger_references(triggers, bindings) do
    triggers.triggers
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {_id, trigger}, :ok ->
      if Map.has_key?(bindings.bindings, trigger.binding),
        do: {:cont, :ok},
        else: {:halt, {:error, :unknown_trigger_binding}}
    end)
  end

  defp annotate({:ok, value}, _category), do: {:ok, value}
  defp annotate({:error, reason}, category), do: {:error, {category, reason}}
end

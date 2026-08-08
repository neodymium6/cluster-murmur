defmodule ClusterMurmur.Config.Catalog do
  @moduledoc """
  A validated version 1 event-group, persona, and binding catalog.

  Category parsers run independently before binding references are resolved,
  so include order cannot affect validity. Trigger and routing configuration is
  intentionally outside this partial assembly stage.
  """

  alias ClusterMurmur.Config.{
    Bindings,
    ConversationDefaults,
    DocumentSet,
    EventGroups,
    LLM,
    LoadedDocument,
    Manifest,
    Personas,
    StateTracking
  }

  @categories [:event_groups, :personas, :bindings, :triggers, :routing]

  @derive {Inspect, only: [:version]}
  @enforce_keys [:version, :event_groups, :personas, :bindings]
  defstruct [:version, :event_groups, :personas, :bindings]

  @type t :: %__MODULE__{
          version: 1,
          event_groups: EventGroups.t(),
          personas: Personas.t(),
          bindings: Bindings.t()
        }

  @type error ::
          :invalid_catalog
          | :unknown_binding_group
          | :unknown_binding_persona
          | {:event_groups, EventGroups.error()}
          | {:personas, Personas.error()}
          | {:bindings, Bindings.error()}

  @doc "Parses implemented categories and resolves binding references."
  @spec parse(Path.t(), term()) :: {:ok, t()} | {:error, error()}
  def parse(config_path, %DocumentSet{} = document_set) do
    with :ok <- validate_document_set(document_set),
         documents = document_set.documents,
         {:ok, event_groups} <-
           annotate(EventGroups.parse_documents(documents.event_groups), :event_groups),
         {:ok, personas} <-
           annotate(Personas.parse_documents(config_path, documents.personas), :personas),
         {:ok, bindings} <- annotate(Bindings.parse_documents(documents.bindings), :bindings),
         :ok <- validate_references(event_groups, personas, bindings) do
      {:ok,
       %__MODULE__{
         version: 1,
         event_groups: event_groups,
         personas: personas,
         bindings: bindings
       }}
    end
  end

  def parse(_config_path, _document_set), do: {:error, :invalid_catalog}

  defp validate_document_set(%DocumentSet{manifest: manifest, documents: documents}) do
    with :ok <- validate_manifest(manifest),
         true <- is_map(documents) and map_size(documents) == length(@categories),
         true <- Enum.sort(Map.keys(documents)) == Enum.sort(@categories),
         true <- Enum.all?(@categories, &loaded_document_list?(Map.fetch!(documents, &1))) do
      :ok
    else
      _failure -> {:error, :invalid_catalog}
    end
  end

  defp validate_document_set(_document_set), do: {:error, :invalid_catalog}

  defp validate_manifest(
         %Manifest{
           version: 1,
           includes: includes,
           llm: llm,
           state_tracking: state_tracking,
           conversation_defaults: conversation_defaults
         } = manifest
       )
       when is_map(includes) do
    if map_size(includes) == length(@categories) and
         Enum.sort(Map.keys(includes)) == Enum.sort(@categories) do
      decoded_includes = Map.new(@categories, &{Atom.to_string(&1), Map.fetch!(includes, &1)})

      with {:ok, llm_document} <- LLM.to_document(llm),
           {:ok, state_tracking_document} <- StateTracking.to_document(state_tracking),
           {:ok, conversation_defaults_document} <-
             ConversationDefaults.to_document(conversation_defaults),
           {:ok, ^manifest} <-
             Manifest.parse(%{
               "version" => 1,
               "includes" => decoded_includes,
               "llm" => llm_document,
               "state_tracking" => state_tracking_document,
               "conversation_defaults" => conversation_defaults_document
             }) do
        :ok
      else
        _failure -> {:error, :invalid_catalog}
      end
    else
      {:error, :invalid_catalog}
    end
  end

  defp validate_manifest(_manifest), do: {:error, :invalid_catalog}

  defp loaded_document_list?([]), do: true

  defp loaded_document_list?([
         %LoadedDocument{path: path, document: document} | documents
       ])
       when is_binary(path) and is_map(document),
       do: loaded_document_list?(documents)

  defp loaded_document_list?(_documents), do: false

  defp validate_references(event_groups, personas, bindings) do
    bindings.bindings
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:ok, fn {_id, binding}, :ok ->
      case validate_binding_references(binding, event_groups.groups, personas.personas) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_binding_references(binding, event_groups, personas) do
    if Map.has_key?(event_groups, binding.group) do
      validate_candidate_references(binding.candidates, personas)
    else
      {:error, :unknown_binding_group}
    end
  end

  defp validate_candidate_references([], _personas), do: :ok

  defp validate_candidate_references([candidate | candidates], personas) do
    if Map.has_key?(personas, candidate.persona) do
      validate_candidate_references(candidates, personas)
    else
      {:error, :unknown_binding_persona}
    end
  end

  defp annotate({:ok, value}, _category), do: {:ok, value}
  defp annotate({:error, reason}, category), do: {:error, {category, reason}}
end

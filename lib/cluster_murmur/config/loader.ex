defmodule ClusterMurmur.Config.Loader do
  @moduledoc """
  Builds a bounded load plan from a top-level configuration manifest.

  Loading stops at the first failed stage. Errors identify that stage while
  preserving the stable, value-free reason returned by the responsible
  decoder, validator, or resolver.
  """

  alias ClusterMurmur.Config.{
    DocumentDecoder,
    DocumentSet,
    IncludeResolver,
    LoadedDocument,
    LoadPlan,
    Manifest
  }

  @type error ::
          {:document, DocumentDecoder.error()}
          | {:manifest, Manifest.error()}
          | {:includes, IncludeResolver.error()}
          | {:included_document, DocumentDecoder.error()}

  @doc """
  Decodes and validates a manifest, then resolves all of its include categories.
  """
  @spec load_manifest(Path.t()) :: {:ok, LoadPlan.t()} | {:error, error()}
  def load_manifest(config_path) do
    with {:ok, document} <- annotate(DocumentDecoder.decode_file(config_path), :document),
         {:ok, manifest} <- annotate(Manifest.parse(document), :manifest),
         {:ok, files} <-
           annotate(
             IncludeResolver.resolve_categories(config_path, manifest.includes),
             :includes
           ) do
      {:ok, %LoadPlan{manifest: manifest, files: files}}
    end
  end

  @doc """
  Builds a load plan and decodes every included YAML document once.

  The returned documents remain unvalidated beyond the generic bounded YAML
  contract.
  """
  @spec load_documents(Path.t()) :: {:ok, DocumentSet.t()} | {:error, error()}
  def load_documents(config_path) do
    with {:ok, plan} <- load_manifest(config_path),
         {:ok, documents} <-
           annotate(decode_categories(plan.files), :included_document) do
      {:ok, %DocumentSet{manifest: plan.manifest, documents: documents}}
    end
  end

  defp decode_categories(files) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {category, paths}, {:ok, documents, cache} ->
      case decode_paths(paths, cache) do
        {:ok, loaded, cache} ->
          {:cont, {:ok, Map.put(documents, category, loaded), cache}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, documents, _cache} -> {:ok, documents}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_paths(paths, cache) do
    Enum.reduce_while(paths, {:ok, [], cache}, fn path, {:ok, loaded, cache} ->
      case load_document(path, cache) do
        {:ok, document, cache} -> {:cont, {:ok, [document | loaded], cache}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, loaded, cache} -> {:ok, Enum.reverse(loaded), cache}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_document(path, cache) do
    case Map.fetch(cache, path) do
      {:ok, document} ->
        {:ok, document, cache}

      :error ->
        with {:ok, decoded} <- DocumentDecoder.decode_file(path) do
          document = %LoadedDocument{path: path, document: decoded}
          {:ok, document, Map.put(cache, path, document)}
        end
    end
  end

  defp annotate({:ok, value}, _stage), do: {:ok, value}
  defp annotate({:error, reason}, stage), do: {:error, {stage, reason}}
end

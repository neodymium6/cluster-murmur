defmodule ClusterMurmur.Config.Loader do
  @moduledoc """
  Builds a bounded load plan from a top-level configuration manifest.

  Loading stops at the first failed stage. Errors identify that stage while
  preserving the stable, value-free reason returned by the responsible
  decoder, validator, or resolver.
  """

  alias ClusterMurmur.Config.{DocumentDecoder, IncludeResolver, LoadPlan, Manifest}

  @type error ::
          {:document, DocumentDecoder.error()}
          | {:manifest, Manifest.error()}
          | {:includes, IncludeResolver.error()}

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

  defp annotate({:ok, value}, _stage), do: {:ok, value}
  defp annotate({:error, reason}, stage), do: {:error, {stage, reason}}
end

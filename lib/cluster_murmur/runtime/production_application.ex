defmodule ClusterMurmur.Runtime.ProductionApplication do
  @moduledoc """
  Builds the complete child list for the standalone production application.

  Construction performs only bounded configuration and secret-file reads. It
  does not read a clock, recover state, start a worker, bind a listener, or
  contact an external service. The returned child order keeps a fixed health
  listener available around repository and runtime replacement, and creates a
  readiness service before persistence and lets the recovery-gated supervisor
  acquire its lease only after all schedulers start.
  """

  alias ClusterMurmur.Runtime.{
    ExternalIngestionServer,
    HealthServer,
    HealthSettings,
    ProductionRecoveredRuntimeOptions,
    ReadyMarker,
    RecoveredRuntimeSupervisor,
    SystemClock
  }

  alias ClusterMurmur.Ingestion.HTTPSettings
  alias ClusterMurmur.Persistence.ExternalEventCommitStore
  alias ClusterMurmur.Startup

  @config_path_environment "CLUSTER_MURMUR_CONFIG_PATH"
  @max_path_bytes 4_096

  @type environment_reader :: (String.t() -> {:ok, String.t()} | :error)

  @doc "Builds the fixed standalone production child list without starting it."
  @spec child_specs(environment_reader()) ::
          {:ok, [Supervisor.child_spec() | {module(), term()}]}
          | {:error, :invalid_production_application}
  def child_specs(environment_reader \\ &System.fetch_env/1)

  def child_specs(environment_reader) when is_function(environment_reader, 1) do
    with {:ok, config_path} <- read_config_path(environment_reader),
         {:ok, prepared} <- Startup.prepare(config_path, environment_reader),
         {:ok, options} <- ProductionRecoveredRuntimeOptions.build(prepared),
         {:ok, health_settings} <- HealthSettings.load(environment_reader),
         {:ok, ingestion_settings} <-
           HTTPSettings.load(prepared.configuration.external_ingestion, environment_reader) do
      {:ok,
       [
         {HealthServer, health_settings},
         {ReadyMarker, :production},
         ClusterMurmur.Repo
       ] ++
         ingestion_children(ingestion_settings, prepared.configuration.external_ingestion) ++
         [{RecoveredRuntimeSupervisor, options}]}
    else
      _failure -> {:error, :invalid_production_application}
    end
  rescue
    _error -> {:error, :invalid_production_application}
  catch
    _kind, _reason -> {:error, :invalid_production_application}
  end

  def child_specs(_environment_reader), do: {:error, :invalid_production_application}

  defp ingestion_children(:disabled, _configuration), do: []

  defp ingestion_children(%HTTPSettings{} = settings, configuration) do
    options = %ExternalIngestionServer.Options{
      settings: settings,
      configuration: configuration,
      clock: SystemClock,
      commit: &ExternalEventCommitStore.commit/3
    }

    [{ExternalIngestionServer, options}]
  end

  defp read_config_path(environment_reader) do
    case environment_reader.(@config_path_environment) do
      {:ok, path} -> validate_config_path(path)
      _failure -> {:error, :invalid_production_application}
    end
  end

  defp validate_config_path(path)
       when is_binary(path) and byte_size(path) in 1..@max_path_bytes do
    if String.valid?(path) and not String.contains?(path, <<0>>) and
         Path.type(path) == :absolute do
      {:ok, path}
    else
      {:error, :invalid_production_application}
    end
  end

  defp validate_config_path(_path), do: {:error, :invalid_production_application}
end

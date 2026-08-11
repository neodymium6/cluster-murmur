defmodule ClusterMurmur.Startup do
  @moduledoc """
  Prepares validated configuration and deployment settings before runtime start.

  Preparation performs bounded configuration and secret-file reads only. It
  does not start workers, connect to providers, observe infrastructure, or
  publish messages.
  """

  alias ClusterMurmur.Config.{Configuration, Loader}
  alias ClusterMurmur.Runtime.{ResponderScheduleSettings, SchedulerSettings}
  alias ClusterMurmur.RuntimeSettings

  defmodule Prepared do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [
      :configuration,
      :runtime_settings,
      :scheduler_settings,
      :responder_schedule_settings
    ]
    defstruct [
      :configuration,
      :runtime_settings,
      :scheduler_settings,
      :responder_schedule_settings
    ]

    @type t :: %__MODULE__{
            configuration: ClusterMurmur.Config.Configuration.t(),
            runtime_settings: ClusterMurmur.RuntimeSettings.t(),
            scheduler_settings: ClusterMurmur.Runtime.SchedulerSettings.t(),
            responder_schedule_settings: ClusterMurmur.Runtime.ResponderScheduleSettings.t()
          }
  end

  @prepared_keys Prepared.__struct__() |> Map.keys()
  @prepared_key_count length(@prepared_keys)

  @type error ::
          :invalid_startup
          | {:configuration, Loader.error()}
          | {:runtime_settings, RuntimeSettings.error()}
          | {:scheduler_settings, SchedulerSettings.error()}
          | {:responder_schedule_settings, ResponderScheduleSettings.error()}

  @doc "Loads every implemented startup input without starting external work."
  @spec prepare(term(), RuntimeSettings.environment_reader()) ::
          {:ok, Prepared.t()} | {:error, error()}
  def prepare(config_path, environment_reader \\ &System.fetch_env/1)

  def prepare(config_path, environment_reader) when is_function(environment_reader, 1) do
    with {:ok, configuration} <-
           annotate(Loader.load_configuration(config_path), :configuration),
         {:ok, runtime_settings} <-
           annotate(RuntimeSettings.load(configuration, environment_reader), :runtime_settings),
         {:ok, scheduler_settings} <-
           annotate(SchedulerSettings.load(environment_reader), :scheduler_settings),
         {:ok, responder_schedule_settings} <-
           annotate(
             ResponderScheduleSettings.load(environment_reader),
             :responder_schedule_settings
           ) do
      prepared = %Prepared{
        configuration: configuration,
        runtime_settings: runtime_settings,
        scheduler_settings: scheduler_settings,
        responder_schedule_settings: responder_schedule_settings
      }

      case validate(prepared) do
        :ok -> {:ok, prepared}
        {:error, :invalid_startup} = error -> error
      end
    end
  rescue
    _error -> {:error, :invalid_startup}
  catch
    _kind, _reason -> {:error, :invalid_startup}
  end

  def prepare(_config_path, _environment_reader), do: {:error, :invalid_startup}

  @doc "Revalidates one exact prepared startup value before worker construction."
  @spec validate(term()) :: :ok | {:error, :invalid_startup}
  def validate(%Prepared{} = prepared) do
    if exact_prepared?(prepared) and Configuration.validate(prepared.configuration) == :ok and
         RuntimeSettings.validate(prepared.runtime_settings) == :ok and
         SchedulerSettings.validate(prepared.scheduler_settings) == :ok and
         ResponderScheduleSettings.validate(prepared.responder_schedule_settings) == :ok do
      :ok
    else
      {:error, :invalid_startup}
    end
  rescue
    _error -> {:error, :invalid_startup}
  catch
    _kind, _reason -> {:error, :invalid_startup}
  end

  def validate(_prepared), do: {:error, :invalid_startup}

  defp exact_prepared?(prepared) do
    map_size(prepared) == @prepared_key_count and
      Enum.all?(@prepared_keys, &Map.has_key?(prepared, &1))
  end

  defp annotate({:ok, value}, _stage), do: {:ok, value}
  defp annotate({:error, reason}, stage), do: {:error, {stage, reason}}
end

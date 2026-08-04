defmodule ClusterMurmur.Release do
  @moduledoc """
  Explicit OTP release operations for the fixed application repository.

  Migrations run only from an operator-invoked release evaluation. Operators
  must stop every application instance before invoking it; the local guard can
  reject only an application or repository in the evaluation VM. Application
  startup never mutates the schema automatically.
  """

  alias ClusterMurmur.Repo

  @application :cluster_murmur
  @migration_timeout_ms 60_000
  @cleanup_timeout_ms 5_000

  @type error :: :migration_failed

  @doc "Applies every packaged migration while the application is stopped."
  @spec migrate() :: :ok | {:error, error()}
  def migrate do
    lock = {{__MODULE__, :migration}, self()}

    case :global.trans(lock, &migrate_exclusively/0, [node()], 0) do
      :aborted -> {:error, :migration_failed}
      result -> result
    end
  rescue
    _error -> {:error, :migration_failed}
  catch
    _kind, _reason -> {:error, :migration_failed}
  end

  @doc "Applies migrations or raises one value-free error for release evaluation."
  @spec migrate!() :: :ok | no_return()
  def migrate! do
    case migrate() do
      :ok -> :ok
      {:error, :migration_failed} -> raise "database migration failed"
    end
  end

  defp migrate_exclusively do
    if migration_environment_stopped?() do
      with_suppressed_logging(&run_owned_migration/0)
    else
      {:error, :migration_failed}
    end
  end

  defp migration_environment_stopped? do
    not application_started?(@application) and Process.whereis(Repo) == nil
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {started, _description, _version} ->
      started == application
    end)
  end

  defp with_suppressed_logging(fun) do
    %{level: previous_level} = :logger.get_primary_config()

    case :logger.set_primary_config(:level, :none) do
      :ok ->
        try do
          fun.()
        after
          :logger.set_primary_config(:level, previous_level)
        end

      _failure ->
        {:error, :migration_failed}
    end
  end

  defp run_owned_migration do
    with true <- migration_environment_stopped?(),
         :ok <- Application.ensure_loaded(@application),
         {:ok, [Repo]} <- Application.fetch_env(@application, :ecto_repos) do
      with_started_applications(
        fn -> Application.ensure_all_started(:ecto_sql, :temporary) end,
        fn ->
          with_started_applications(
            fn -> Repo.__adapter__().ensure_all_started(Repo.config(), :temporary) end,
            fn -> with_owned_repo(&run_isolated_migration/0) end
          )
        end
      )
    else
      _failure -> {:error, :migration_failed}
    end
  rescue
    _error -> {:error, :migration_failed}
  catch
    _kind, _reason -> {:error, :migration_failed}
  end

  defp with_started_applications(start, operation) do
    case start.() do
      {:ok, started_apps} ->
        operation_result = safely(operation)
        cleanup_result = stop_started_applications(started_apps)
        combine_results(operation_result, cleanup_result)

      _failure ->
        {:error, :migration_failed}
    end
  end

  defp with_owned_repo(operation) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      if migration_environment_stopped?() do
        case Repo.start_link(pool_size: 1) do
          {:ok, repo} ->
            Process.unlink(repo)
            operation_result = safely(operation)
            cleanup_result = stop_repo(repo)
            flush_exit(repo)
            combine_results(operation_result, cleanup_result)

          _failure ->
            {:error, :migration_failed}
        end
      else
        {:error, :migration_failed}
      end
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp run_isolated_migration do
    caller = self()
    reply_tag = make_ref()

    {runner, monitor} =
      spawn_monitor(fn -> send(caller, {reply_tag, packaged_migration_result()}) end)

    receive do
      {^reply_tag, result} ->
        runner_result = await_runner_down(monitor, runner)
        combine_results(result, runner_result)

      {:DOWN, ^monitor, :process, ^runner, _reason} ->
        {:error, :migration_failed}
    after
      @migration_timeout_ms ->
        Process.exit(runner, :kill)
        await_runner_down(monitor, runner)
        {:error, :migration_failed}
    end
  end

  defp packaged_migration_result do
    case Ecto.Migrator.run(Repo, :up,
           all: true,
           log: false,
           log_migrations_sql: false,
           log_migrator_sql: false
         ) do
      versions when is_list(versions) -> :ok
      _failure -> {:error, :migration_failed}
    end
  rescue
    _error -> {:error, :migration_failed}
  catch
    _kind, _reason -> {:error, :migration_failed}
  end

  defp await_runner_down(monitor, runner) do
    receive do
      {:DOWN, ^monitor, :process, ^runner, _reason} -> :ok
    after
      @cleanup_timeout_ms ->
        Process.exit(runner, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^runner, _reason} -> :ok
        after
          @cleanup_timeout_ms ->
            Process.demonitor(monitor, [:flush])
            {:error, :migration_failed}
        end
    end
  end

  defp stop_started_applications(started_apps) do
    started_apps
    |> Enum.reverse()
    |> Enum.uniq()
    |> Enum.reduce(:ok, fn application, cleanup_result ->
      case Application.stop(application) do
        :ok -> cleanup_result
        {:error, {:not_started, ^application}} -> cleanup_result
        _failure -> {:error, :migration_failed}
      end
    end)
  end

  defp stop_repo(repo) do
    monitor = Process.monitor(repo)

    try do
      Supervisor.stop(repo, :shutdown, @cleanup_timeout_ms)
    catch
      :exit, _reason -> Process.exit(repo, :kill)
    end

    receive do
      {:DOWN, ^monitor, :process, ^repo, _reason} -> :ok
    after
      @cleanup_timeout_ms ->
        Process.exit(repo, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^repo, _reason} -> :ok
        after
          @cleanup_timeout_ms ->
            Process.demonitor(monitor, [:flush])
            {:error, :migration_failed}
        end
    end
  end

  defp flush_exit(repo) do
    receive do
      {:EXIT, ^repo, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp safely(operation) do
    operation.()
  rescue
    _error -> {:error, :migration_failed}
  catch
    _kind, _reason -> {:error, :migration_failed}
  end

  defp combine_results(:ok, :ok), do: :ok
  defp combine_results(_operation_result, _cleanup_result), do: {:error, :migration_failed}
end

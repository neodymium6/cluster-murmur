defmodule ClusterMurmur.Repo do
  @moduledoc """
  Single-writer SQLite repository for durable application state.

  Domain modules use dedicated persistence boundaries rather than issuing
  arbitrary queries through this module. The configured path must have trusted
  ancestry that untrusted principals cannot rename or replace.
  """

  use Ecto.Repo,
    otp_app: :cluster_murmur,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(context, config) do
    if Keyword.has_key?(config, :url), do: raise(ArgumentError, "invalid database configuration")

    {allow_in_memory?, config} = Keyword.pop(config, :allow_in_memory, false)

    with {:ok, database} <- Keyword.fetch(config, :database),
         :ok <- prepare_database(database, context, allow_in_memory?) do
      {:ok, config}
    else
      _failure -> raise ArgumentError, "invalid database configuration"
    end
  end

  defp prepare_database(":memory:", context, true) when context in [:runtime, :supervisor],
    do: :ok

  defp prepare_database(database, context, _allow_in_memory?)
       when context in [:runtime, :supervisor] and is_binary(database) do
    with :ok <- validate_database_path(database) do
      prepare_database_storage(database, context)
    end
  end

  defp prepare_database(_database, _context, _allow_in_memory?),
    do: {:error, :invalid_database_path}

  defp validate_database_path(database) do
    if byte_size(database) in 1..4_096 and String.valid?(database) and
         not String.contains?(database, <<0>>) and Path.type(database) == :absolute do
      :ok
    else
      {:error, :invalid_database_path}
    end
  end

  defp prepare_database_storage(_database, :runtime), do: :ok

  defp prepare_database_storage(database, :supervisor) do
    with :ok <- ensure_private_directory(Path.dirname(database)),
         :ok <- ensure_private_file(database) do
      :ok
    end
  end

  defp ensure_private_directory(directory) do
    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory, mode: mode}} ->
        require_mode(mode, 0o700)

      _failure ->
        {:error, :invalid_database_directory}
    end
  end

  defp ensure_private_file(database) do
    case File.lstat(database) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        require_mode(mode, 0o600)

      {:error, :enoent} ->
        with :ok <- File.write(database, "", [:exclusive]),
             :ok <- File.chmod(database, 0o600),
             {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(database) do
          require_mode(mode, 0o600)
        end

      _failure ->
        {:error, :invalid_database_file}
    end
  end

  defp require_mode(mode, expected) do
    if Bitwise.band(mode, 0o777) == expected,
      do: :ok,
      else: {:error, :unsafe_database_permissions}
  end
end

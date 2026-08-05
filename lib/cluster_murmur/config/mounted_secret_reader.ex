defmodule ClusterMurmur.Config.MountedSecretReader do
  @moduledoc """
  Reads one bounded UTF-8 value from a mounted secret file.

  Public configuration supplies only an environment-variable name. The named
  environment variable must contain an absolute path to a regular file. Error
  values never include the environment value, resolved path, or file contents.

  This boundary only loads an opaque value. Callers remain responsible for
  validating that value as an API key, webhook URL, or another expected secret
  type before using it.
  """

  alias ClusterMurmur.Config.Value

  @max_path_bytes 4 * 1_024
  @max_secret_bytes 16 * 1_024

  @type environment_reader :: (String.t() -> {:ok, String.t()} | :error)
  @type error ::
          :empty_secret
          | :invalid_secret_encoding
          | :invalid_secret_environment_variable
          | :invalid_secret_file_path
          | :missing_secret_file_path
          | :secret_file_target_invalid
          | :secret_file_too_large
          | :unreadable_secret_file

  @doc "Reads the mounted secret referenced by one environment-variable name."
  @spec read(term(), environment_reader()) :: {:ok, String.t()} | {:error, error()}
  def read(environment_variable_name, environment_reader \\ &System.fetch_env/1) do
    with {:ok, environment_variable_name} <-
           validate_environment_variable_name(environment_variable_name),
         {:ok, path} <- read_path(environment_reader, environment_variable_name),
         :ok <- validate_path(path),
         :ok <- validate_target(path),
         {:ok, secret} <- read_secret(path) do
      validate_secret(secret)
    end
  end

  defp validate_environment_variable_name(value) do
    case Value.environment_variable_name(value) do
      {:ok, name} -> {:ok, name}
      {:error, _reason} -> {:error, :invalid_secret_environment_variable}
    end
  end

  defp read_path(environment_reader, environment_variable_name)
       when is_function(environment_reader, 1) do
    case environment_reader.(environment_variable_name) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      :error -> {:error, :missing_secret_file_path}
      _result -> {:error, :invalid_secret_file_path}
    end
  end

  defp read_path(_environment_reader, _environment_variable_name),
    do: {:error, :invalid_secret_file_path}

  defp validate_path(path) do
    if path != "" and byte_size(path) <= @max_path_bytes and String.valid?(path) and
         Path.type(path) == :absolute do
      :ok
    else
      {:error, :invalid_secret_file_path}
    end
  end

  defp validate_target(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :secret_file_target_invalid}

      {:error, reason} when reason in [:enoent, :enotdir, :eloop, :emlink] ->
        {:error, :secret_file_target_invalid}

      {:error, _reason} ->
        {:error, :unreadable_secret_file}
    end
  end

  defp read_secret(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_secret_bytes + 1)) do
      {:ok, :eof} -> {:ok, ""}
      {:ok, secret} when is_binary(secret) -> {:ok, secret}
      _failure -> {:error, :unreadable_secret_file}
    end
  end

  defp validate_secret(secret) when byte_size(secret) > @max_secret_bytes,
    do: {:error, :secret_file_too_large}

  defp validate_secret(secret) do
    if String.valid?(secret) do
      case String.trim(secret) do
        "" -> {:error, :empty_secret}
        trimmed -> {:ok, trimmed}
      end
    else
      {:error, :invalid_secret_encoding}
    end
  end
end

defmodule ClusterMurmur.Generation.ProviderSettings do
  @moduledoc """
  Loads bounded runtime settings for the OpenAI-compatible provider.

  The input is an exact, normalized public configuration projection containing
  environment-variable names and numeric limits. Deployment values are read at
  this boundary. No provider request or network connection is performed.
  """

  alias ClusterMurmur.Config.{MountedSecretReader, Value}

  @config_keys [
    :api_key_file_env,
    :base_url_env,
    :max_output_tokens,
    :model_env,
    :provider,
    :timeout_ms
  ]
  @max_base_url_bytes 2_048
  @max_model_bytes 256
  @max_timeout_ms 120_000
  @max_output_tokens 4_096

  @derive {Inspect, only: [:provider, :timeout_ms, :max_output_tokens]}
  @enforce_keys [:provider, :base_url, :model, :api_key, :timeout_ms, :max_output_tokens]
  defstruct [:provider, :base_url, :model, :api_key, :timeout_ms, :max_output_tokens]

  @type t :: %__MODULE__{
          provider: :openai_compatible,
          base_url: String.t(),
          model: String.t(),
          api_key: String.t(),
          timeout_ms: pos_integer(),
          max_output_tokens: pos_integer()
        }

  @type environment_reader :: MountedSecretReader.environment_reader()
  @type error ::
          :invalid_provider_settings
          | :invalid_provider_base_url
          | :invalid_provider_model
          | :missing_provider_base_url
          | :missing_provider_model
          | {:api_key, MountedSecretReader.error()}

  @doc "Loads one exact runtime provider-settings projection without connecting."
  @spec load(term(), environment_reader()) :: {:ok, t()} | {:error, error()}
  def load(config, environment_reader \\ &System.fetch_env/1)

  def load(config, environment_reader)
      when is_map(config) and not is_struct(config) and is_function(environment_reader, 1) do
    with :ok <- validate_config(config),
         {:ok, base_url} <-
           read_environment(
             config.base_url_env,
             environment_reader,
             @max_base_url_bytes,
             :missing_provider_base_url,
             :invalid_provider_base_url
           ),
         {:ok, base_url} <- validate_base_url(base_url),
         {:ok, model} <-
           read_environment(
             config.model_env,
             environment_reader,
             @max_model_bytes,
             :missing_provider_model,
             :invalid_provider_model
           ),
         {:ok, api_key} <- read_api_key(config.api_key_file_env, environment_reader) do
      {:ok,
       %__MODULE__{
         provider: :openai_compatible,
         base_url: base_url,
         model: model,
         api_key: api_key,
         timeout_ms: config.timeout_ms,
         max_output_tokens: config.max_output_tokens
       }}
    end
  rescue
    _error -> {:error, :invalid_provider_settings}
  catch
    _kind, _reason -> {:error, :invalid_provider_settings}
  end

  def load(_config, _environment_reader), do: {:error, :invalid_provider_settings}

  defp validate_config(config) do
    if exact_keys?(config) and config.provider == :openai_compatible and
         valid_environment_name?(config.base_url_env) and
         valid_environment_name?(config.model_env) and
         valid_environment_name?(config.api_key_file_env) and
         is_integer(config.timeout_ms) and config.timeout_ms in 1..@max_timeout_ms and
         is_integer(config.max_output_tokens) and
         config.max_output_tokens in 1..@max_output_tokens do
      :ok
    else
      {:error, :invalid_provider_settings}
    end
  end

  defp exact_keys?(config), do: Map.keys(config) |> Enum.sort() == @config_keys

  defp valid_environment_name?(value) do
    match?({:ok, _name}, Value.environment_variable_name(value))
  end

  defp read_environment(name, environment_reader, max_bytes, missing_error, invalid_error) do
    case environment_reader.(name) do
      {:ok, value} when is_binary(value) and byte_size(value) <= max_bytes ->
        validate_environment_value(value, invalid_error)

      :error ->
        {:error, missing_error}

      _result ->
        {:error, invalid_error}
    end
  end

  defp validate_environment_value(value, invalid_error) do
    if String.valid?(value) do
      case String.trim(value) do
        "" -> {:error, invalid_error}
        trimmed -> {:ok, trimmed}
      end
    else
      {:error, invalid_error}
    end
  end

  defp validate_base_url(value) do
    with false <- Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value),
         normalized when is_binary(normalized) <- :uri_string.normalize(value),
         {:ok, uri} <- URI.new(normalized),
         true <- valid_base_uri?(uri) do
      {:ok, normalized}
    else
      _failure -> {:error, :invalid_provider_base_url}
    end
  end

  defp valid_base_uri?(%URI{
         scheme: scheme,
         host: host,
         port: port,
         userinfo: nil,
         query: nil,
         fragment: nil
       })
       when scheme in ["http", "https"],
       do: is_binary(host) and host != "" and is_integer(port) and port in 1..65_535

  defp valid_base_uri?(_uri), do: false

  defp read_api_key(environment_variable_name, environment_reader) do
    case MountedSecretReader.read(environment_variable_name, environment_reader) do
      {:ok, api_key} -> {:ok, api_key}
      {:error, reason} -> {:error, {:api_key, reason}}
    end
  end
end

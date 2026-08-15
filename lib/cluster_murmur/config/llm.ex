defmodule ClusterMurmur.Config.LLM do
  @moduledoc """
  Validates the version 1 public LLM provider configuration.

  Only environment-variable names and bounded numeric limits enter this value.
  Provider endpoints, model names, and API keys remain deployment values loaded
  by the separate runtime settings boundary.
  """

  alias ClusterMurmur.Config.{Duration, Value}

  @document_keys [
    "api_key_file_env",
    "base_url_env",
    "max_output_tokens",
    "model_env",
    "provider",
    "reasoning_effort",
    "timeout"
  ]
  @required_document_keys @document_keys -- ["reasoning_effort"]
  @document_key_count length(@document_keys)
  @required_document_key_count length(@required_document_keys)
  @struct_keys [
    :__struct__,
    :api_key_file_env,
    :base_url_env,
    :max_output_tokens,
    :model_env,
    :provider,
    :reasoning_effort,
    :timeout_ms
  ]
  @struct_key_count length(@struct_keys)
  @max_timeout_bytes 32
  @max_timeout_ms 120_000
  @max_output_tokens 32_768
  @reasoning_efforts [:none, :minimal, :low, :medium, :high, :xhigh, :max]
  @reasoning_efforts_by_name Map.new(@reasoning_efforts, &{Atom.to_string(&1), &1})

  @derive {Inspect, only: [:provider, :timeout_ms, :max_output_tokens, :reasoning_effort]}
  @enforce_keys [
    :provider,
    :base_url_env,
    :model_env,
    :api_key_file_env,
    :timeout_ms,
    :max_output_tokens
  ]
  defstruct [
    :provider,
    :base_url_env,
    :model_env,
    :api_key_file_env,
    :timeout_ms,
    :max_output_tokens,
    :reasoning_effort
  ]

  @type t :: %__MODULE__{
          provider: :openai_compatible,
          base_url_env: String.t(),
          model_env: String.t(),
          api_key_file_env: String.t(),
          timeout_ms: pos_integer(),
          max_output_tokens: pos_integer(),
          reasoning_effort: nil | :none | :minimal | :low | :medium | :high | :xhigh | :max
        }
  @type error :: :invalid_llm_configuration

  @doc "Parses one exact decoded version 1 LLM mapping."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(document) when is_map(document) and not is_struct(document) do
    with true <- exact_document?(document),
         true <- document["provider"] == "openai_compatible",
         {:ok, base_url_env} <- Value.environment_variable_name(document["base_url_env"]),
         {:ok, model_env} <- Value.environment_variable_name(document["model_env"]),
         {:ok, api_key_file_env} <-
           Value.environment_variable_name(document["api_key_file_env"]),
         {:ok, timeout_ms} <- parse_timeout(document["timeout"]),
         true <- valid_max_output_tokens?(document["max_output_tokens"]),
         {:ok, reasoning_effort} <- parse_reasoning_effort(document) do
      {:ok,
       %__MODULE__{
         provider: :openai_compatible,
         base_url_env: base_url_env,
         model_env: model_env,
         api_key_file_env: api_key_file_env,
         timeout_ms: timeout_ms,
         max_output_tokens: document["max_output_tokens"],
         reasoning_effort: reasoning_effort
       }}
    else
      _failure -> {:error, :invalid_llm_configuration}
    end
  rescue
    _error -> {:error, :invalid_llm_configuration}
  catch
    _kind, _reason -> {:error, :invalid_llm_configuration}
  end

  def parse(_document), do: {:error, :invalid_llm_configuration}

  @doc "Revalidates one exact normalized public LLM value."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{} = llm) do
    if exact_struct?(llm) and llm.provider == :openai_compatible and
         valid_environment_name?(llm.base_url_env) and valid_environment_name?(llm.model_env) and
         valid_environment_name?(llm.api_key_file_env) and is_integer(llm.timeout_ms) and
         llm.timeout_ms in 1..@max_timeout_ms and valid_max_output_tokens?(llm.max_output_tokens) and
         valid_reasoning_effort?(llm.reasoning_effort),
       do: :ok,
       else: {:error, :invalid_llm_configuration}
  rescue
    _error -> {:error, :invalid_llm_configuration}
  catch
    _kind, _reason -> {:error, :invalid_llm_configuration}
  end

  def validate(_llm), do: {:error, :invalid_llm_configuration}

  @doc false
  @spec to_provider_settings_projection(term()) :: {:ok, map()} | {:error, error()}
  def to_provider_settings_projection(llm) do
    case validate(llm) do
      :ok ->
        {:ok,
         %{
           provider: llm.provider,
           base_url_env: llm.base_url_env,
           model_env: llm.model_env,
           api_key_file_env: llm.api_key_file_env,
           timeout_ms: llm.timeout_ms,
           max_output_tokens: llm.max_output_tokens,
           reasoning_effort: llm.reasoning_effort
         }}

      {:error, :invalid_llm_configuration} = error ->
        error
    end
  end

  @doc false
  @spec to_document(term()) :: {:ok, map()} | {:error, error()}
  def to_document(llm) do
    case validate(llm) do
      :ok ->
        document = %{
          "provider" => "openai_compatible",
          "base_url_env" => llm.base_url_env,
          "model_env" => llm.model_env,
          "api_key_file_env" => llm.api_key_file_env,
          "timeout" => Integer.to_string(llm.timeout_ms) <> "ms",
          "max_output_tokens" => llm.max_output_tokens
        }

        {:ok, maybe_put_reasoning_effort(document, llm.reasoning_effort)}

      {:error, :invalid_llm_configuration} = error ->
        error
    end
  end

  defp exact_document?(document) do
    map_size(document) in @required_document_key_count..@document_key_count and
      Enum.all?(@required_document_keys, &Map.has_key?(document, &1)) and
      Enum.all?(Map.keys(document), &(&1 in @document_keys))
  end

  defp exact_struct?(llm) do
    map_size(llm) == @struct_key_count and Enum.all?(@struct_keys, &Map.has_key?(llm, &1))
  end

  defp parse_timeout(value)
       when is_binary(value) and byte_size(value) in 1..@max_timeout_bytes do
    with true <- String.valid?(value),
         {:ok, timeout_ms} <- Duration.parse(value),
         true <- timeout_ms in 1..@max_timeout_ms do
      {:ok, timeout_ms}
    else
      _failure -> {:error, :invalid_llm_configuration}
    end
  end

  defp parse_timeout(_value), do: {:error, :invalid_llm_configuration}

  defp valid_environment_name?(value),
    do: match?({:ok, _name}, Value.environment_variable_name(value))

  defp valid_max_output_tokens?(value),
    do: is_integer(value) and value in 1..@max_output_tokens

  defp parse_reasoning_effort(document) do
    case Map.fetch(document, "reasoning_effort") do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) -> Map.fetch(@reasoning_efforts_by_name, value)
      {:ok, _invalid} -> :error
    end
  end

  defp valid_reasoning_effort?(value), do: is_nil(value) or value in @reasoning_efforts

  defp maybe_put_reasoning_effort(document, nil), do: document

  defp maybe_put_reasoning_effort(document, reasoning_effort),
    do: Map.put(document, "reasoning_effort", Atom.to_string(reasoning_effort))
end

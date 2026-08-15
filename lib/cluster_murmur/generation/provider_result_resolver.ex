defmodule ClusterMurmur.Generation.ProviderResultResolver do
  @moduledoc """
  Resolves one completed provider result into LLM text or a fallback decision.

  This pure boundary does not call a provider, construct a fallback message,
  persist state, or publish output.
  """

  alias ClusterMurmur.Generation.{
    PersonaProjection,
    PersonaProjectionValidator,
    ProviderOutputNormalizer
  }

  @max_output_characters 16 * 1_024
  @normalization_reasons [
    :blank_output,
    :character_limit_exceeded,
    :invalid_provider_output,
    :invalid_unicode
  ]

  @type fallback_reason ::
          :blank_output
          | :character_limit_exceeded
          | :invalid_provider_output
          | :invalid_unicode
          | :provider_failure
  @type decision :: {:llm, String.t()} | {:fallback, fallback_reason()}
  @type error :: :invalid_provider_resolution

  @doc "Returns normalized LLM text or a diagnostics-free fallback decision."
  @spec resolve(term(), term(), term()) :: {:ok, decision()} | {:error, error()}
  def resolve(result, %PersonaProjection{} = persona, character_limit)
      when is_integer(character_limit) and character_limit in 1..@max_output_characters do
    with :ok <- PersonaProjectionValidator.validate(persona) do
      resolve_result(result, persona, character_limit)
    else
      _failure -> {:error, :invalid_provider_resolution}
    end
  rescue
    _error -> {:error, :invalid_provider_resolution}
  catch
    _kind, _reason -> {:error, :invalid_provider_resolution}
  end

  def resolve(_result, _persona, _character_limit),
    do: {:error, :invalid_provider_resolution}

  defp resolve_result({:ok, raw}, persona, character_limit) do
    case ProviderOutputNormalizer.normalize(raw, persona, character_limit) do
      {:ok, content} -> {:ok, {:llm, content}}
      {:error, reason} when reason in @normalization_reasons -> {:ok, {:fallback, reason}}
    end
  end

  defp resolve_result(_provider_failure, _persona, _character_limit),
    do: {:ok, {:fallback, :provider_failure}}
end

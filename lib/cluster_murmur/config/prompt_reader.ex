defmodule ClusterMurmur.Config.PromptReader do
  @moduledoc """
  Reads bounded UTF-8 prompt files referenced by configuration documents.

  References are portable relative paths resolved from the canonical source
  document. Targets must remain inside the canonical configuration root. The
  configuration tree must be trusted and read-only while resolving and reading
  a prompt, matching the include-loader boundary.
  """

  alias ClusterMurmur.Config.PathResolver

  @max_prompt_bytes 64 * 1_024
  @max_reference_bytes 512

  @type error ::
          :empty_prompt
          | :invalid_config_path
          | :invalid_prompt_encoding
          | :invalid_prompt_reference
          | :invalid_source_path
          | :prompt_reference_too_long
          | :prompt_target_invalid
          | :prompt_target_outside_root
          | :prompt_too_large
          | :unreadable_prompt

  @doc "Reads one prompt relative to its decoded configuration source file."
  @spec read(Path.t(), Path.t(), term()) :: {:ok, String.t()} | {:error, error()}
  def read(config_path, source_path, reference)
      when is_binary(config_path) and is_binary(source_path) do
    with :ok <- validate_reference(reference),
         {:ok, root} <- PathResolver.config_root(config_path),
         {:ok, source} <- validate_source(source_path, root),
         {:ok, prompt_path} <- resolve_prompt(source, reference, root),
         {:ok, prompt} <- read_prompt(prompt_path) do
      {:ok, prompt}
    end
  end

  def read(config_path, _source_path, _reference) when not is_binary(config_path),
    do: {:error, :invalid_config_path}

  def read(_config_path, source_path, _reference) when not is_binary(source_path),
    do: {:error, :invalid_source_path}

  defp validate_reference(reference) when is_binary(reference) do
    cond do
      byte_size(reference) > @max_reference_bytes ->
        {:error, :prompt_reference_too_long}

      reference == "" or not String.valid?(reference) ->
        {:error, :invalid_prompt_reference}

      Path.type(reference) != :relative ->
        {:error, :invalid_prompt_reference}

      String.ends_with?(reference, "/") or String.contains?(reference, "//") ->
        {:error, :invalid_prompt_reference}

      not Regex.match?(~r/\A[A-Za-z0-9._\/-]+\z/, reference) ->
        {:error, :invalid_prompt_reference}

      true ->
        :ok
    end
  end

  defp validate_reference(_reference), do: {:error, :invalid_prompt_reference}

  defp validate_source(source_path, root) do
    with {:ok, source} <- PathResolver.canonical_path(source_path),
         true <- PathResolver.inside_root?(source, root),
         true <- PathResolver.portable_target?(source, root),
         {:ok, %File.Stat{type: :regular}} <- File.stat(source) do
      {:ok, source}
    else
      _failure -> {:error, :invalid_source_path}
    end
  end

  defp resolve_prompt(source, reference, root) do
    candidate = Path.join(Path.dirname(source), reference)

    case PathResolver.canonical_path(candidate) do
      {:ok, prompt_path} ->
        validate_prompt_target(prompt_path, root)

      {:error, reason} when reason in [:eloop, :emlink, :enoent, :enotdir] ->
        {:error, :prompt_target_invalid}

      {:error, _reason} ->
        {:error, :unreadable_prompt}
    end
  end

  defp validate_prompt_target(prompt_path, root) do
    cond do
      not PathResolver.inside_root?(prompt_path, root) ->
        {:error, :prompt_target_outside_root}

      not PathResolver.portable_target?(prompt_path, root) ->
        {:error, :prompt_target_invalid}

      true ->
        case File.stat(prompt_path) do
          {:ok, %File.Stat{type: :regular}} -> {:ok, prompt_path}
          {:ok, %File.Stat{}} -> {:error, :prompt_target_invalid}
          {:error, _reason} -> {:error, :unreadable_prompt}
        end
    end
  end

  defp read_prompt(prompt_path) do
    case File.open(prompt_path, [:read, :binary], &IO.binread(&1, @max_prompt_bytes + 1)) do
      {:ok, :eof} ->
        {:error, :empty_prompt}

      {:ok, <<>>} ->
        {:error, :empty_prompt}

      {:ok, prompt} when is_binary(prompt) and byte_size(prompt) > @max_prompt_bytes ->
        {:error, :prompt_too_large}

      {:ok, prompt} when is_binary(prompt) ->
        if String.valid?(prompt),
          do: {:ok, prompt},
          else: {:error, :invalid_prompt_encoding}

      _failure ->
        {:error, :unreadable_prompt}
    end
  end
end

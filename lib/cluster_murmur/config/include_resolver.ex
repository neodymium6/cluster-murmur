defmodule ClusterMurmur.Config.IncludeResolver do
  @moduledoc """
  Resolves bounded configuration includes relative to the top-level file.

  Version 1 include patterns are portable ASCII relative paths. They may use
  `*` within a path component, but do not support recursive globs or other glob
  operators. Every pattern must resolve to at least one regular file. Returned
  paths are canonical, unique, and sorted so filesystem order has no effect.
  """

  @max_patterns 64
  @max_files 256
  @max_pattern_bytes 512
  @max_symlinks 40

  @type error ::
          :filesystem_error
          | :include_not_found
          | :include_pattern_too_long
          | :include_target_invalid
          | :include_target_outside_root
          | :invalid_config_path
          | :invalid_include_pattern
          | :invalid_includes
          | :too_many_include_patterns
          | :too_many_included_files

  @spec resolve(Path.t(), term()) :: {:ok, [Path.t()]} | {:error, error()}
  def resolve(config_path, patterns) when is_binary(config_path) and is_list(patterns) do
    with :ok <- validate_pattern_count(patterns),
         {:ok, root} <- config_root(config_path),
         {:ok, paths} <- resolve_patterns(root, patterns) do
      {:ok, paths |> Enum.uniq() |> Enum.sort()}
    end
  end

  def resolve(_config_path, _patterns), do: {:error, :invalid_includes}

  defp validate_pattern_count(patterns) do
    if length(patterns) <= @max_patterns,
      do: :ok,
      else: {:error, :too_many_include_patterns}
  end

  defp config_root(config_path) do
    expanded_config = Path.expand(config_path)

    with {:ok, root} <- canonical_path(Path.dirname(expanded_config)),
         {:ok, canonical_config} <- canonical_path(expanded_config),
         true <- inside_root?(canonical_config, root),
         {:ok, %File.Stat{type: :regular}} <- File.stat(canonical_config) do
      {:ok, root}
    else
      _failure -> {:error, :invalid_config_path}
    end
  end

  defp resolve_patterns(root, patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, accumulated} ->
      with :ok <- validate_pattern(pattern),
           {:ok, matches} <- expand_pattern(root, pattern),
           :ok <- validate_match_count(matches),
           {:ok, resolved} <- resolve_matches(matches, root),
           {:ok, combined} <- combine_matches(accumulated, resolved) do
        {:cont, {:ok, combined}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_pattern(pattern) when is_binary(pattern) do
    cond do
      byte_size(pattern) > @max_pattern_bytes ->
        {:error, :include_pattern_too_long}

      not portable_pattern?(pattern) ->
        {:error, :invalid_include_pattern}

      Path.type(pattern) != :relative ->
        {:error, :invalid_include_pattern}

      ".." in Path.split(pattern) ->
        {:error, :invalid_include_pattern}

      String.contains?(pattern, "**") ->
        {:error, :invalid_include_pattern}

      true ->
        :ok
    end
  end

  defp validate_pattern(_pattern), do: {:error, :invalid_include_pattern}

  defp portable_pattern?(pattern) do
    pattern != "" and String.valid?(pattern) and
      Regex.match?(~r/\A[A-Za-z0-9._*\/-]+\z/, pattern)
  end

  defp expand_pattern(root, pattern) do
    matches = root |> Path.join(pattern) |> Path.wildcard()

    if matches == [],
      do: {:error, :include_not_found},
      else: {:ok, matches}
  end

  defp validate_match_count(matches) do
    if length(matches) <= @max_files,
      do: :ok,
      else: {:error, :too_many_included_files}
  end

  defp combine_matches(accumulated, resolved) do
    combined = Enum.uniq(resolved ++ accumulated)

    if length(combined) <= @max_files,
      do: {:ok, combined},
      else: {:error, :too_many_included_files}
  end

  defp resolve_matches(matches, root) do
    Enum.reduce_while(matches, {:ok, []}, fn path, {:ok, accumulated} ->
      with {:ok, canonical} <- canonical_path(path),
           true <- inside_root?(canonical, root),
           {:ok, %File.Stat{type: :regular}} <- File.stat(canonical) do
        {:cont, {:ok, [canonical | accumulated]}}
      else
        false ->
          {:halt, {:error, :include_target_outside_root}}

        {:ok, %File.Stat{}} ->
          {:halt, {:error, :include_target_invalid}}

        {:error, reason} when reason in [:eloop, :emlink] ->
          {:halt, {:error, :include_target_invalid}}

        _failure ->
          {:halt, {:error, :filesystem_error}}
      end
    end)
  end

  defp inside_root?(path, root) do
    path == root or String.starts_with?(path, root_prefix(root))
  end

  defp root_prefix("/"), do: "/"
  defp root_prefix(root), do: root <> "/"

  defp canonical_path(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_components(nil, MapSet.new(), 0)
  end

  defp resolve_components([], current, _seen, _symlink_count), do: {:ok, current}

  defp resolve_components([component | remaining], current, seen, symlink_count) do
    candidate = join_component(current, component)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} when symlink_count < @max_symlinks ->
        resolve_symlink(candidate, remaining, seen, symlink_count)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :eloop}

      {:ok, %File.Stat{}} ->
        resolve_components(remaining, candidate, seen, symlink_count)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_symlink(candidate, remaining, seen, symlink_count) do
    if MapSet.member?(seen, candidate) do
      {:error, :eloop}
    else
      with {:ok, target} <- File.read_link(candidate) do
        target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.join(Path.dirname(candidate), target)

        [target | remaining]
        |> Path.join()
        |> Path.expand()
        |> Path.split()
        |> resolve_components(nil, MapSet.put(seen, candidate), symlink_count + 1)
      end
    end
  end

  defp join_component(nil, component), do: component
  defp join_component(current, component), do: Path.join(current, component)
end

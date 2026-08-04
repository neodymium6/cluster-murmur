defmodule ClusterMurmur.Config.IncludeResolver do
  @moduledoc """
  Resolves bounded configuration includes relative to the top-level file.

  Version 1 include patterns are portable ASCII relative paths. They may use
  `*` within a path component, but do not support recursive globs or other glob
  operators. Every pattern must resolve to at least one regular file. Returned
  paths are canonical, unique, and sorted so filesystem order has no effect.
  Category-aware resolution shares traversal and file budgets across the
  entire manifest and returns a deterministic file list for each category.
  """

  @max_patterns 64
  @max_files 256
  @max_inspected_entries 1_024
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
          | :too_many_include_entries
          | :too_many_include_patterns
          | :too_many_included_files

  @spec resolve(Path.t(), term()) :: {:ok, [Path.t()]} | {:error, error()}
  def resolve(config_path, patterns) when is_binary(config_path) do
    with {:ok, categories} <- resolve_categories(config_path, %{all: patterns}) do
      {:ok, Map.fetch!(categories, :all)}
    end
  end

  def resolve(_config_path, _patterns), do: {:error, :invalid_includes}

  @doc "Resolves manifest includes with limits shared across every category."
  @spec resolve_categories(Path.t(), term()) ::
          {:ok, %{optional(atom()) => [Path.t()]}} | {:error, error()}
  def resolve_categories(config_path, categories)
      when is_binary(config_path) and is_map(categories) do
    with {:ok, entries} <- validate_categories(categories),
         {:ok, root} <- config_root(config_path),
         {:ok, state} <- resolve_category_entries(root, entries) do
      {:ok, finalize_categories(state.categories)}
    end
  end

  def resolve_categories(_config_path, _categories), do: {:error, :invalid_includes}

  defp validate_categories(categories) do
    categories
    |> Map.to_list()
    |> Enum.sort_by(fn {category, _patterns} -> category end)
    |> Enum.reduce_while({:ok, [], 0}, fn
      {category, patterns}, {:ok, entries, count} when is_atom(category) ->
        case count_patterns(patterns, count) do
          {:ok, count} -> {:cont, {:ok, [{category, patterns} | entries], count}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _entry, _state ->
        {:halt, {:error, :invalid_includes}}
    end)
    |> case do
      {:ok, entries, _count} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp count_patterns([], count), do: {:ok, count}

  defp count_patterns([_pattern | remaining], count) when count < @max_patterns,
    do: count_patterns(remaining, count + 1)

  defp count_patterns([_pattern | _remaining], _count),
    do: {:error, :too_many_include_patterns}

  defp count_patterns(_patterns, _count), do: {:error, :invalid_includes}

  defp config_root(config_path) do
    with {:ok, root} <- canonical_path(Path.dirname(config_path)),
         {:ok, canonical_config} <- canonical_path(config_path),
         true <- inside_root?(canonical_config, root),
         {:ok, %File.Stat{type: :regular}} <- File.stat(canonical_config) do
      {:ok, root}
    else
      _failure -> {:error, :invalid_config_path}
    end
  end

  defp resolve_category_entries(root, entries) do
    initial = %{
      categories: %{},
      files: MapSet.new(),
      inspected_entries: 0,
      resolved_patterns: %{}
    }

    Enum.reduce_while(entries, {:ok, initial}, fn {category, patterns}, {:ok, state} ->
      state = put_in(state.categories[category], MapSet.new())

      case resolve_category_patterns(root, category, patterns, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_category_patterns(root, category, patterns, state) do
    Enum.reduce_while(patterns, {:ok, state}, fn pattern, {:ok, state} ->
      case resolve_pattern(root, pattern, state) do
        {:ok, resolved, state} ->
          category_files = Enum.reduce(resolved, state.categories[category], &MapSet.put(&2, &1))
          {:cont, {:ok, put_in(state.categories[category], category_files)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_pattern(root, pattern, state) do
    with :ok <- validate_pattern(pattern) do
      case Map.fetch(state.resolved_patterns, pattern) do
        {:ok, resolved} -> {:ok, resolved, state}
        :error -> resolve_new_pattern(root, pattern, state)
      end
    end
  end

  defp resolve_new_pattern(root, pattern, state) do
    with {:ok, resolved, inspected_entries} <-
           walk_components(
             [root],
             Path.split(pattern),
             root,
             state.inspected_entries
           ),
         {:ok, files} <- combine_files(state.files, resolved) do
      state = %{
        state
        | files: files,
          inspected_entries: inspected_entries,
          resolved_patterns: Map.put(state.resolved_patterns, pattern, resolved)
      }

      {:ok, resolved, state}
    end
  end

  defp finalize_categories(categories) do
    Map.new(categories, fn {category, files} ->
      {category, files |> MapSet.to_list() |> Enum.sort()}
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

      Enum.any?(Path.split(pattern), &(&1 in [".", ".."])) ->
        {:error, :invalid_include_pattern}

      String.contains?(pattern, "**") ->
        {:error, :invalid_include_pattern}

      String.ends_with?(pattern, "/") or String.contains?(pattern, "//") ->
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

  defp walk_components(directories, [component | remaining], root, inspected_entries) do
    final? = remaining == []

    directories
    |> Enum.reduce_while({:ok, [], inspected_entries}, fn directory,
                                                          {:ok, accumulated, inspected} ->
      with {:ok, names, inspected} <- candidate_names(directory, component, inspected),
           {:ok, resolved} <- resolve_candidates(directory, names, root, final?) do
        {:cont, {:ok, resolved ++ accumulated, inspected}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> continue_walk(remaining, root)
  end

  defp continue_walk({:ok, [], _inspected_entries}, _remaining, _root),
    do: {:error, :include_not_found}

  defp continue_walk({:ok, resolved, inspected_entries}, [], _root),
    do: {:ok, resolved, inspected_entries}

  defp continue_walk({:ok, directories, inspected_entries}, remaining, root),
    do: walk_components(Enum.uniq(directories), remaining, root, inspected_entries)

  defp continue_walk({:error, reason}, _remaining, _root), do: {:error, reason}

  defp candidate_names(directory, component, inspected_entries) do
    if String.contains?(component, "*") do
      with {:ok, names} <- File.ls(directory),
           true <- Enum.all?(names, &String.valid?/1),
           {:ok, inspected_entries} <- add_inspected_entries(inspected_entries, length(names)) do
        matcher = glob_matcher(component)

        matching_names =
          names
          |> Enum.filter(&glob_match?(&1, component, matcher))
          |> Enum.sort()

        {:ok, matching_names, inspected_entries}
      else
        {:error, :too_many_include_entries} = error -> error
        false -> {:error, :include_target_invalid}
        {:error, _reason} -> {:error, :filesystem_error}
      end
    else
      {:ok, [component], inspected_entries}
    end
  end

  defp add_inspected_entries(current, additional) do
    if current + additional <= @max_inspected_entries,
      do: {:ok, current + additional},
      else: {:error, :too_many_include_entries}
  end

  defp glob_matcher(component) do
    source = component |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)
    Regex.compile!("\\A" <> source <> "\\z", "s")
  end

  defp glob_match?(name, component, matcher) do
    visible? = not String.starts_with?(name, ".") or String.starts_with?(component, ".")
    visible? and Regex.match?(matcher, name)
  end

  defp resolve_candidates(directory, names, root, final?) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, accumulated} ->
      candidate = Path.join(directory, name)

      case resolve_candidate(candidate, root, final?) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | accumulated]}}
        :skip -> {:cont, {:ok, accumulated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_candidate(candidate, root, final?) do
    case File.lstat(candidate) do
      {:error, :enoent} ->
        :skip

      {:ok, %File.Stat{}} ->
        canonicalize_and_classify_candidate(candidate, root, final?)

      _failure ->
        {:error, :filesystem_error}
    end
  end

  defp canonicalize_and_classify_candidate(candidate, root, final?) do
    case canonical_path(candidate) do
      {:ok, canonical} ->
        cond do
          not inside_root?(canonical, root) ->
            {:error, :include_target_outside_root}

          not portable_target?(canonical, root) ->
            {:error, :include_target_invalid}

          true ->
            stat_and_classify_target(canonical, final?)
        end

      {:error, reason} when reason in [:eloop, :emlink, :enoent, :enotdir] ->
        {:error, :include_target_invalid}

      _failure ->
        {:error, :filesystem_error}
    end
  end

  defp stat_and_classify_target(canonical, final?) do
    case File.stat(canonical) do
      {:ok, %File.Stat{type: type}} -> classify_target(canonical, type, final?)
      {:error, :enoent} -> :skip
      {:error, _reason} -> {:error, :filesystem_error}
    end
  end

  defp classify_target(canonical, :regular, true), do: {:ok, canonical}
  defp classify_target(canonical, :directory, false), do: {:ok, canonical}
  defp classify_target(_canonical, _type, true), do: {:error, :include_target_invalid}
  defp classify_target(_canonical, _type, false), do: :skip

  defp portable_target?(path, root) do
    if path == root do
      true
    else
      path
      |> Path.relative_to(root)
      |> Path.split()
      |> Enum.all?(fn component ->
        component not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, component)
      end)
    end
  end

  defp combine_files(files, resolved) do
    combined = Enum.reduce(resolved, files, &MapSet.put(&2, &1))

    if MapSet.size(combined) <= @max_files,
      do: {:ok, combined},
      else: {:error, :too_many_included_files}
  end

  defp inside_root?(path, root) do
    path == root or String.starts_with?(path, root_prefix(root))
  end

  defp root_prefix("/"), do: "/"
  defp root_prefix(root), do: root <> "/"

  defp canonical_path(path) do
    with {:ok, components} <- absolute_components(path) do
      resolve_components(components, nil, 0)
    end
  end

  defp absolute_components(path) do
    if Path.type(path) == :absolute do
      {:ok, path_components(path)}
    else
      case File.cwd() do
        {:ok, cwd} -> {:ok, Path.split(cwd) ++ path_components(path)}
        {:error, _reason} -> {:error, :filesystem_error}
      end
    end
  end

  defp resolve_components([], current, _symlink_count), do: {:ok, current}

  defp resolve_components(["/" | remaining], _current, symlink_count),
    do: resolve_components(remaining, "/", symlink_count)

  defp resolve_components(["." | remaining], current, symlink_count),
    do: resolve_components(remaining, current, symlink_count)

  defp resolve_components([".." | remaining], current, symlink_count),
    do: resolve_components(remaining, Path.dirname(current), symlink_count)

  defp resolve_components([component | remaining], current, symlink_count) do
    candidate = join_component(current, component)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} when symlink_count < @max_symlinks ->
        resolve_symlink(candidate, remaining, current, symlink_count)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :eloop}

      {:ok, %File.Stat{type: :directory}} when remaining != [] ->
        resolve_components(remaining, candidate, symlink_count)

      {:ok, %File.Stat{}} when remaining == [] ->
        resolve_components(remaining, candidate, symlink_count)

      {:ok, %File.Stat{}} ->
        {:error, :enotdir}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_symlink(candidate, remaining, current, symlink_count) do
    with {:ok, target} <- File.read_link(candidate) do
      target_components = path_components(target)

      if Path.type(target) == :absolute do
        resolve_components(target_components ++ remaining, nil, symlink_count + 1)
      else
        resolve_components(target_components ++ remaining, current, symlink_count + 1)
      end
    end
  end

  defp path_components(path) do
    components = Path.split(path)

    if String.ends_with?(path, "/"),
      do: components ++ ["."],
      else: components
  end

  defp join_component(nil, component), do: component
  defp join_component(current, component), do: Path.join(current, component)
end

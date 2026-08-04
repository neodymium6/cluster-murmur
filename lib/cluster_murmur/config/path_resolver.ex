defmodule ClusterMurmur.Config.PathResolver do
  @moduledoc false

  @max_symlinks 40

  @type canonical_error :: :eloop | :emlink | :enoent | :enotdir | :filesystem_error

  @spec config_root(Path.t()) :: {:ok, Path.t()} | {:error, :invalid_config_path}
  def config_root(config_path) when is_binary(config_path) do
    with {:ok, root} <- canonical_path(Path.dirname(config_path)),
         {:ok, canonical_config} <- canonical_path(config_path),
         true <- inside_root?(canonical_config, root),
         {:ok, %File.Stat{type: :regular}} <- File.stat(canonical_config) do
      {:ok, root}
    else
      _failure -> {:error, :invalid_config_path}
    end
  end

  def config_root(_config_path), do: {:error, :invalid_config_path}

  @spec canonical_path(Path.t()) :: {:ok, Path.t()} | {:error, canonical_error() | atom()}
  def canonical_path(path) when is_binary(path) do
    with {:ok, components} <- absolute_components(path) do
      resolve_components(components, nil, 0)
    end
  end

  def canonical_path(_path), do: {:error, :filesystem_error}

  @spec inside_root?(Path.t(), Path.t()) :: boolean()
  def inside_root?(path, root) when is_binary(path) and is_binary(root) do
    path == root or String.starts_with?(path, root_prefix(root))
  end

  def inside_root?(_path, _root), do: false

  @spec portable_target?(Path.t(), Path.t()) :: boolean()
  def portable_target?(path, root) when is_binary(path) and is_binary(root) do
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

  def portable_target?(_path, _root), do: false

  defp root_prefix("/"), do: "/"
  defp root_prefix(root), do: root <> "/"

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

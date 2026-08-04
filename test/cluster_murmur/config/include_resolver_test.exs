defmodule ClusterMurmur.Config.IncludeResolverTest do
  use ExUnit.Case, async: true

  alias ClusterMurmur.Config.IncludeResolver

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cluster-murmur-include-test-#{System.unique_integer([:positive])}"
      )

    config_root = Path.join(test_root, "config")
    config_file = Path.join(config_root, "cluster-murmur.yaml")
    File.mkdir_p!(config_root)
    File.write!(config_file, "version: 1\n")

    on_exit(fn -> File.rm_rf!(test_root) end)

    %{config_file: config_file, config_root: config_root, test_root: test_root}
  end

  test "resolves relative files and globs uniquely in deterministic order", context do
    first = write_fixture(context.config_root, "personas/first.yaml")
    second = write_fixture(context.config_root, "personas/second.yaml")
    routing = write_fixture(context.config_root, "routing.yaml")

    assert IncludeResolver.resolve(context.config_file, [
             "personas/*.yaml",
             "routing.yaml",
             "personas/first.yaml"
           ]) == {:ok, Enum.sort([first, routing, second])}
  end

  test "accepts an empty optional include list", context do
    assert IncludeResolver.resolve(context.config_file, []) == {:ok, []}
  end

  test "requires every declared pattern to match", context do
    write_fixture(context.config_root, "personas/observer.yaml")

    assert IncludeResolver.resolve(context.config_file, [
             "personas/*.yaml",
             "bindings/*.yaml"
           ]) == {:error, :include_not_found}
  end

  test "rejects absolute, traversing, recursive, extended, and non-portable patterns", context do
    invalid_patterns = [
      "/tmp/example.yaml",
      "../example.yaml",
      "personas/./example.yaml",
      "personas/**/example.yaml",
      "personas/example?.yaml",
      "personas/[ab].yaml",
      "personas/{a,b}.yaml",
      "personas/観測者.yaml",
      "",
      nil
    ]

    for pattern <- invalid_patterns do
      assert IncludeResolver.resolve(context.config_file, [pattern]) ==
               {:error, :invalid_include_pattern}
    end
  end

  test "bounds pattern length and count", context do
    assert IncludeResolver.resolve(context.config_file, [String.duplicate("a", 513)]) ==
             {:error, :include_pattern_too_long}

    assert IncludeResolver.resolve(context.config_file, List.duplicate("a.yaml", 65)) ==
             {:error, :too_many_include_patterns}
  end

  test "bounds the total number of matched files", context do
    for number <- 1..257 do
      write_fixture(context.config_root, "personas/#{number}.yaml")
    end

    assert IncludeResolver.resolve(context.config_file, ["personas/*.yaml"]) ==
             {:error, :too_many_included_files}
  end

  test "bounds inspected directory entries before traversing further", context do
    for number <- 1..1_025 do
      write_fixture(context.config_root, "entries/#{number}.yaml")
    end

    assert IncludeResolver.resolve(context.config_file, ["entries/*.yaml"]) ==
             {:error, :too_many_include_entries}
  end

  test "applies the inspected-entry budget cumulatively across patterns", context do
    for directory <- ["first", "second"] do
      write_fixture(context.config_root, "#{directory}/matched.yaml")

      for number <- 1..512 do
        write_fixture(context.config_root, "#{directory}/#{number}.txt")
      end
    end

    assert IncludeResolver.resolve(context.config_file, [
             "first/*.yaml",
             "second/*.yaml"
           ]) == {:error, :too_many_include_entries}
  end

  test "applies the file limit after deduplicating same-pattern aliases", context do
    target = write_fixture(context.config_root, ".data/shared.yaml")
    aliases = Path.join(context.config_root, "aliases")
    File.mkdir_p!(aliases)

    for number <- 1..257 do
      File.ln_s!("../.data/shared.yaml", Path.join(aliases, "#{number}.yaml"))
    end

    assert IncludeResolver.resolve(context.config_file, ["aliases/*.yaml"]) == {:ok, [target]}
  end

  test "allows symlinks whose canonical targets stay inside the configuration root", context do
    target = write_fixture(context.config_root, ".data/observer.yaml")
    link = Path.join(context.config_root, "observer.yaml")
    File.ln_s!(".data/observer.yaml", link)

    assert IncludeResolver.resolve(context.config_file, ["observer.yaml"]) == {:ok, [target]}
  end

  test "allows finite repeated traversal of the same safe symlink", context do
    target = write_fixture(context.config_root, "file.yaml")
    nested = Path.join(context.config_root, "nested")
    File.mkdir_p!(nested)
    File.ln_s!("..", Path.join(nested, "up"))

    assert IncludeResolver.resolve(context.config_file, [
             "nested/up/nested/up/file.yaml"
           ]) == {:ok, [target]}
  end

  test "allows a safe intermediate symlink whose target is the root", context do
    target = write_fixture(context.config_root, "file.yaml")
    File.ln_s!(".", Path.join(context.config_root, "alias"))

    assert IncludeResolver.resolve(context.config_file, ["alias/file.yaml"]) == {:ok, [target]}
  end

  test "rejects symlinks whose canonical targets escape the configuration root", context do
    outside = write_fixture(context.test_root, "private.yaml")
    link = Path.join(context.config_root, "outside.yaml")
    File.ln_s!(outside, link)

    assert IncludeResolver.resolve(context.config_file, ["outside.yaml"]) ==
             {:error, :include_target_outside_root}
  end

  test "rejects an outside symlink before descending into it", context do
    outside_directory = Path.join(context.test_root, "outside")
    write_fixture(outside_directory, "private.yaml")
    File.ln_s!(outside_directory, Path.join(context.config_root, "linked"))

    assert IncludeResolver.resolve(context.config_file, ["linked/*.yaml"]) ==
             {:error, :include_target_outside_root}
  end

  test "resolves parent components after preceding symlinks", context do
    actual = Path.join(context.config_root, "actual")
    outside_directory = Path.join(context.test_root, "outside-directory")
    write_fixture(actual, "outside.yaml")
    write_fixture(context.test_root, "outside.yaml")
    File.mkdir_p!(outside_directory)
    File.ln_s!(outside_directory, Path.join(actual, "link"))
    File.ln_s!("actual/link/../outside.yaml", Path.join(context.config_root, "alias.yaml"))

    assert IncludeResolver.resolve(context.config_file, ["alias.yaml"]) ==
             {:error, :include_target_outside_root}
  end

  test "rejects a portable symlink alias for a non-portable canonical filename", context do
    write_fixture(context.config_root, ".data/観測者.yaml")
    File.ln_s!(".data/観測者.yaml", Path.join(context.config_root, "observer.yaml"))

    assert IncludeResolver.resolve(context.config_file, ["observer.yaml"]) ==
             {:error, :include_target_invalid}
  end

  test "rejects directories and symlink loops as include targets", context do
    directory = Path.join(context.config_root, "personas")
    File.mkdir_p!(directory)

    assert IncludeResolver.resolve(context.config_file, ["personas"]) ==
             {:error, :include_target_invalid}

    first_link = Path.join(context.config_root, "first.yaml")
    second_link = Path.join(context.config_root, "second.yaml")
    File.ln_s!("second.yaml", first_link)
    File.ln_s!("first.yaml", second_link)

    assert IncludeResolver.resolve(context.config_file, ["first.yaml"]) ==
             {:error, :include_target_invalid}
  end

  test "rejects dangling symlinks as invalid include targets", context do
    File.ln_s!("missing.yaml", Path.join(context.config_root, "dangling.yaml"))

    assert IncludeResolver.resolve(context.config_file, ["dangling.yaml"]) ==
             {:error, :include_target_invalid}
  end

  test "bounds symlink expansion even without a cycle", context do
    write_fixture(context.config_root, "target.yaml")

    for number <- 1..41 do
      target = if number == 41, do: "target.yaml", else: "link#{number + 1}.yaml"
      File.ln_s!(target, Path.join(context.config_root, "link#{number}.yaml"))
    end

    assert IncludeResolver.resolve(context.config_file, ["link1.yaml"]) ==
             {:error, :include_target_invalid}
  end

  test "rejects an invalid top-level configuration path", context do
    assert IncludeResolver.resolve(Path.join(context.config_root, "missing.yaml"), []) ==
             {:error, :invalid_config_path}

    assert IncludeResolver.resolve(nil, []) == {:error, :invalid_includes}
    assert IncludeResolver.resolve(context.config_file, nil) == {:error, :invalid_includes}
  end

  defp write_fixture(root, relative_path) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "example: true\n")
    Path.expand(path)
  end
end

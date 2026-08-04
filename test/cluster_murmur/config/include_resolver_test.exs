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

  test "applies the file limit after deduplicating canonical paths", context do
    for number <- 1..256 do
      write_fixture(context.config_root, "personas/#{number}.yaml")
    end

    assert {:ok, paths} =
             IncludeResolver.resolve(context.config_file, [
               "personas/*.yaml",
               "personas/*.yaml"
             ])

    assert length(paths) == 256
  end

  test "allows symlinks whose canonical targets stay inside the configuration root", context do
    target = write_fixture(context.config_root, ".data/observer.yaml")
    link = Path.join(context.config_root, "observer.yaml")
    File.ln_s!(".data/observer.yaml", link)

    assert IncludeResolver.resolve(context.config_file, ["observer.yaml"]) == {:ok, [target]}
  end

  test "rejects symlinks whose canonical targets escape the configuration root", context do
    outside = write_fixture(context.test_root, "private.yaml")
    link = Path.join(context.config_root, "outside.yaml")
    File.ln_s!(outside, link)

    assert IncludeResolver.resolve(context.config_file, ["outside.yaml"]) ==
             {:error, :include_target_outside_root}
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
